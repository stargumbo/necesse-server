#!/bin/sh
set -eu

# The game files come from Steam through DepotDownloader (anonymous dedicated-server access), the same
# acquirer on amd64 and arm64, at build time and here. It is an unmodified official release binary (see
# NOTICE); its per-directory state lives in <dir>/.DepotDownloader. Steam's Linux build also carries an
# x86-64 JRE (jre/) and x86-64 Steamworks natives (linux64/); neither is downloaded, on either
# architecture: the server runs under the image's own JRE and takes its natives from Server.jar
# ("Natives path: INTERNAL"), as the developer's own Linux server zip does. The filelist rule below
# says so, and it is the same one the Dockerfile uses at build time.
DEPOTDOWNLOADER_BIN="/opt/depotdownloader/DepotDownloader"
DEPOT_FILELIST="/tmp/necesse-depot-filelist"
DEPOT_FILELIST_RULE='regex:^(?!jre/|linux64/).*$'
APP_DIR="/app"
APP_ID="1169370"
# "<depot> <manifest>" per line: the depot manifests installed in APP_DIR, written by the image build and
# after every successful download here; the auto-update check compares it with what Steam serves now.
INSTALLED_MANIFESTS_FILE="${APP_DIR}/.necesse-manifests"
RUN_USER="${CONTAINER_USER:-necesse}"
RUN_GROUP="${CONTAINER_GROUP:-necesse}"
RUN_HOME="/home/${RUN_USER}"
# The image's JRE (Eclipse Temurin; JAVA_HOME is set by the base image). JAVA_BIN overrides it.
JAVA_BIN="${JAVA_BIN:-${JAVA_HOME:-/opt/java/openjdk}/bin/java}"
AUTO_UPDATE_FLAG_FILE="/tmp/necesse-auto-update"
# The server only saves on the console `stop` command, not on SIGTERM (verified 2026-09-07: a plain
# SIGTERM exits in <1s without a save). Its stdin is a FIFO held open by this script, so a stop
# request can be typed into the console from the TERM trap and from the auto-update monitor.
CONSOLE_FIFO="/tmp/necesse-console"
# The server's stdout/stderr go through a second FIFO into redact.sh, which replaces the join
# password with **** before anything reaches the container log (the game prints it on start).
# redact.sh also keeps a rotated copy of that output in /tmp/necesse-output.log, which the
# `console` helper (docker exec <container> console players) reads to show a command's reply.
OUTPUT_FIFO="/tmp/necesse-output"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-50}"
# Steam Workshop items are published under the client app id, not the dedicated server's. Each item is
# downloaded into its own directory under WORKSHOP_DIR, outside the bind mount (as SteamCMD's were).
WORKSHOP_APP_ID="1169040"
WORKSHOP_DIR="${RUN_HOME}/.local/share/necesse-workshop"

SERVER_PID=""
AUTO_UPDATE_MONITOR_PID=""
REDACTOR_PID=""
RESOLVED_PASSWORD=""
SERVER_EXIT_CODE=0
AUTO_UPDATE_INTERVAL_MINUTES_NORMALIZED=0
AUTO_UPDATE_INTERVAL_SECONDS=0

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

run_as_user() {
    if is_root; then
        # gosu leaves an already-set HOME alone and the base image sets HOME=/root; pin it to the run user.
        gosu "${RUN_USER}:${RUN_GROUP}" env HOME="${RUN_HOME}" "$@"
    else
        "$@"
    fi
}

adjust_permissions() {
    if ! is_root; then
        return
    fi

    target_gid="${PGID:-$CONTAINER_GID}"
    target_uid="${PUID:-$CONTAINER_UID}"

    current_gid="$(getent group "${RUN_GROUP}" | awk -F: '{print $3}')"
    if [ -n "${target_gid}" ] && [ "${target_gid}" != "${current_gid}" ]; then
        groupmod -o -g "${target_gid}" "${RUN_GROUP}"
    fi

    current_uid="$(id -u "${RUN_USER}")"
    if [ -n "${target_uid}" ] && [ "${target_uid}" != "${current_uid}" ]; then
        usermod -o -u "${target_uid}" -g "${RUN_GROUP}" "${RUN_USER}"
    fi

    chown -R "${RUN_USER}:${RUN_GROUP}" \
        "${APP_DIR}" \
        "${RUN_HOME}"
}

# The game's data directory as launch_server passes it: DATA_DIR when set, else the run user's default.
data_dir() {
    if [ -n "${DATA_DIR:-}" ]; then
        printf '%s' "${DATA_DIR}"
    else
        printf '%s' "${RUN_HOME}/.config/Necesse"
    fi
}

# --- Environment aliases (2.4.0) --------------------------------------------------------------
# Variable names other Necesse images use for the same settings, accepted so that a compose file
# written for one of them works here after changing only the image line: brammys-style upper-case
# names and karyeet-style server.cfg key names. One `alias=canonical` per line; adding an alias is
# one more line. The canonical variable always wins, and an alias that is used produces exactly one
# warning naming the canonical variable. Keys with no counterpart here (karyeet-style `language`,
# `zipSaves`, `port`, ...) are not listed: they live in server.cfg, which carries over untouched.
# JVMARGS (brammys-style) and JVM_OPTS (karyeet-style) were added on the sender's request.
ENV_ALIASES="
WORLD=WORLD_NAME
PASSWORD=SERVER_PASSWORD
OWNER=SERVER_OWNER
SLOTS=SERVER_SLOTS
MOTD=SERVER_MOTD
PAUSE=PAUSE_WHEN_EMPTY
world=WORLD_NAME
password=SERVER_PASSWORD
owner=SERVER_OWNER
slots=SERVER_SLOTS
pauseWhenEmpty=PAUSE_WHEN_EMPTY
giveClientsPower=GIVE_CLIENTS_POWER
JVMARGS=JAVA_OPTS
JVM_OPTS=JAVA_OPTS
"

apply_env_aliases() {
    for pair in ${ENV_ALIASES}; do
        alias_name="${pair%%=*}"
        canonical="${pair#*=}"
        eval "alias_value=\${${alias_name}:-}"
        [ -n "${alias_value}" ] || continue
        eval "canonical_value=\${${canonical}:-}"
        if [ -n "${canonical_value}" ]; then
            echo "WARN: ${alias_name} and ${canonical} are both set; ${canonical} wins and ${alias_name} is ignored." >&2
        else
            echo "WARN: ${alias_name} is accepted as an alias of ${canonical} (for compose files written for another image); set ${canonical} instead." >&2
            export "${canonical}=${alias_value}"
        fi
    done
}

# Defaults that were image ENV values before 2.4.0. They are applied here, after the aliases, because
# inside the container an image default is indistinguishable from an operator's choice, and the
# aliases must be able to fill a variable the image would otherwise have pre-set.
apply_defaults() {
    SERVER_SLOTS="${SERVER_SLOTS:-10}"
    PAUSE_WHEN_EMPTY="${PAUSE_WHEN_EMPTY:-0}"
    GIVE_CLIENTS_POWER="${GIVE_CLIENTS_POWER:-0}"
    export SERVER_SLOTS PAUSE_WHEN_EMPTY GIVE_CLIENTS_POWER
}

# --- Legacy volume layouts (2.4.0) --------------------------------------------------------------
# Other images keep the game's data under another root: brammys-style /necesse/{saves,logs,cfg,mods}
# (the game's -localdir layout) and karyeet-style /root/.config/Necesse/{saves,logs,cfg,mods} (root's
# default data directory). Someone switching to this image keeps those volumes and changes only the
# image line: every legacy path that is a bind mount (or a directory inside a mounted legacy root) is
# linked into this image's data directory, so the game reads and writes the existing files where they
# are. The shim only ever creates symlinks inside the data directory; it never moves, copies or deletes
# a file, and a data-directory entry that already holds files makes the container refuse to start
# rather than guess which copy is the real one. With no legacy path mounted, nothing happens.
LEGACY_LAYOUT_ROOTS="/necesse /root/.config/Necesse"
LEGACY_LAYOUT_NAMES="saves logs cfg mods"
SHIMMED_PATHS=""
CFG_SHIMMED=0

is_mount_point() {
    # Field 5 of /proc/self/mountinfo is the mount point. The paths checked here contain no spaces,
    # so the file's octal escaping does not come into play.
    awk -v path="$1" '$5 == path { found = 1 } END { exit !found }' /proc/self/mountinfo
}

dir_is_empty() {
    [ -z "$(find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]
}

# The run user must be able to search every ancestor of a linked path, and /root, the karyeet-style
# root, is mode 0700 in the image (the game then fails with "Could not create folder for file").
# Search permission only (o+x); nothing is made readable.
make_traversable() {
    p="$(dirname "$1")"
    while [ "${p}" != "/" ]; do
        chmod o+x "${p}"
        p="$(dirname "${p}")"
    done
}

link_legacy_mounts() {
    datadir="$(data_dir)"
    local_dir_flag="$(lowercase "${LOCAL_DIR:-0}")"
    for root in ${LEGACY_LAYOUT_ROOTS}; do
        root_mounted=0
        if is_mount_point "${root}"; then
            root_mounted=1
        fi
        for name in ${LEGACY_LAYOUT_NAMES}; do
            legacy="${root}/${name}"
            note=""
            if is_mount_point "${legacy}"; then
                :
            elif [ "${root_mounted}" -eq 1 ] && [ -d "${legacy}" ]; then
                :
            elif [ "${name}" = "cfg" ] && is_mount_point "${legacy}/server.cfg"; then
                # karyeet-style compose files mount server.cfg (and banned.cfg) as single files inside
                # cfg/. The directory holding them is linked like any other; write_password_to_cfg
                # rewrites the mounted server.cfg in place, since a file mount cannot be renamed over.
                note="; server.cfg is a file mount, written in place"
            else
                continue
            fi
            if [ "${local_dir_flag}" = "1" ] || [ "${local_dir_flag}" = "true" ]; then
                echo "${legacy} is mounted, but LOCAL_DIR=1 keeps the game's data inside the image at ${APP_DIR}; unset LOCAL_DIR to use the mounted directories. Refusing to start." >&2
                exit 1
            fi
            target="${datadir}/${name}"
            if is_root; then
                make_traversable "${legacy}"
            fi
            if [ -L "${target}" ]; then
                if [ "$(readlink "${target}")" = "${legacy}" ]; then
                    echo "Using ${legacy} for ${name} (legacy layout${note})."
                    SHIMMED_PATHS="${SHIMMED_PATHS} ${legacy}"
                    [ "${name}" = "cfg" ] && CFG_SHIMMED=1
                    continue
                fi
                echo "${target} is already a symlink to $(readlink "${target}"), not to the mounted ${legacy}; refusing to guess which one is meant. Remove the link or the mount. Refusing to start." >&2
                exit 1
            fi
            if [ -e "${target}" ]; then
                if [ -d "${target}" ] && dir_is_empty "${target}"; then
                    rmdir "${target}"
                else
                    echo "Both ${legacy} (mounted, legacy layout) and ${target} (this image's data directory) hold files for ${name}; refusing to start rather than pick one. Keep exactly one of them: remove the ${legacy} mount, or move the contents of ${target} out of the data directory. Nothing was changed." >&2
                    exit 1
                fi
            fi
            if [ ! -d "${datadir}" ]; then
                mkdir -p "${datadir}"
                if is_root; then
                    chown "${RUN_USER}:${RUN_GROUP}" "${datadir}"
                fi
            fi
            ln -s "${legacy}" "${target}"
            if is_root; then
                chown -h "${RUN_USER}:${RUN_GROUP}" "${target}"
            fi
            echo "Using ${legacy} for ${name} (legacy layout${note})."
            SHIMMED_PATHS="${SHIMMED_PATHS} ${legacy}"
            [ "${name}" = "cfg" ] && CFG_SHIMMED=1
        done
    done
    # PUID/PGID remap: adjust_permissions' chown -R does not follow symlinks, so the linked trees
    # (root-owned in a karyeet-style setup) are re-owned here. A read-only mount cannot be re-owned;
    # that is only a warning here, because write_password_to_cfg refuses to start with a proper
    # message if the file that matters cannot be written.
    if is_root; then
        for p in ${SHIMMED_PATHS}; do
            if ! chown -R "${RUN_USER}:${RUN_GROUP}" "${p}" 2>/dev/null; then
                echo "WARN: could not change the owner of everything under ${p} (read-only mount?); continuing." >&2
            fi
        done
    fi
}

# --- World auto-detect (2.4.0) ------------------------------------------------------------------
# With WORLD_NAME (and its aliases) unset, the world to load is taken from what is already in
# saves/worlds/, which after the shim includes a legacy layout's saves: exactly one world -> load it;
# none -> the image's long-standing default name "world" (a new world, as before); several -> refuse
# and list them, unless one of them is "world", which is what earlier releases would have loaded.
detect_world() {
    if [ -n "${WORLD_NAME:-}" ]; then
        return
    fi
    worlds_dir="$(data_dir)/saves/worlds"
    found=""
    count=0
    if [ -d "${worlds_dir}" ]; then
        for entry in "${worlds_dir}"/*.zip "${worlds_dir}"/*/; do
            [ -e "${entry}" ] || continue
            world="${entry%/}"
            world="${world##*/}"
            world="${world%.zip}"
            if printf '%s\n' "${found}" | grep -Fxq "${world}"; then
                continue
            fi
            found="${found}${found:+
}${world}"
            count=$((count + 1))
        done
    fi
    case "${count}" in
        0)
            WORLD_NAME="world"
            ;;
        1)
            WORLD_NAME="${found}"
            echo "Loading existing world ${WORLD_NAME} (auto-detected from saves/worlds/)."
            ;;
        *)
            listed="$(printf '%s\n' "${found}" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
            if printf '%s\n' "${found}" | grep -Fxq "world"; then
                WORLD_NAME="world"
                echo "WARN: WORLD_NAME is not set and saves/worlds/ holds several worlds (${listed}); loading 'world', the default name, as earlier releases did. Set WORLD_NAME to choose another." >&2
            else
                echo "WORLD_NAME is not set and saves/worlds/ holds more than one world: ${listed}. Set WORLD_NAME to the one to load; refusing to guess." >&2
                exit 1
            fi
            ;;
    esac
    export WORLD_NAME
}

# --- Join password ---------------------------------------------------------------------------
# The password never goes on the java command line (that shows up in `ps`, `docker top` and the
# game's own "Launched game with arguments" log line). It is resolved once here, written into the
# `password` field of server.cfg (mode 0600) before every launch, scrubbed out of the server's
# stdout/stderr by redact.sh, and removed from the java process environment.
# SERVER_PASSWORD_FILE (for example a Docker secret under /run/secrets) wins over SERVER_PASSWORD.
resolve_password() {
    if [ -n "${SERVER_PASSWORD_FILE:-}" ]; then
        if [ ! -f "${SERVER_PASSWORD_FILE}" ] || [ ! -r "${SERVER_PASSWORD_FILE}" ]; then
            echo "SERVER_PASSWORD_FILE is set to '${SERVER_PASSWORD_FILE}' but that file does not exist or is not readable; refusing to start." >&2
            exit 1
        fi
        # First line only, newline stripped: secret files usually end with one.
        RESOLVED_PASSWORD="$(head -n 1 "${SERVER_PASSWORD_FILE}")"
        if [ -z "${RESOLVED_PASSWORD}" ]; then
            echo "SERVER_PASSWORD_FILE '${SERVER_PASSWORD_FILE}' is empty; refusing to start without a password. Unset it to run an open server." >&2
            exit 1
        fi
        echo "Join password: read from SERVER_PASSWORD_FILE."
    else
        RESOLVED_PASSWORD="${SERVER_PASSWORD:-}"
        if [ -n "${RESOLVED_PASSWORD}" ]; then
            echo "Join password: read from SERVER_PASSWORD."
        fi
    fi

    if [ -z "${RESOLVED_PASSWORD}" ]; then
        echo "Warning: neither SERVER_PASSWORD nor SERVER_PASSWORD_FILE is set; the server will accept joins without a password." >&2
        return
    fi

    # server.cfg is `key = value, // comment` per line, so these two sequences cannot be stored.
    case "${RESOLVED_PASSWORD}" in
        *,*|*//*)
            echo "The join password may not contain a comma or '//' (server.cfg syntax); refusing to start." >&2
            exit 1
            ;;
    esac
}

# Where the game reads server.cfg from, mirroring the flags launch_server passes.
server_cfg_path() {
    if [ -n "${SETTINGS_FILE:-}" ]; then
        printf '%s' "${SETTINGS_FILE}"
        return
    fi

    local_dir_flag="$(lowercase "${LOCAL_DIR:-0}")"
    if [ "$local_dir_flag" = "1" ] || [ "$local_dir_flag" = "true" ]; then
        printf '%s' "${APP_DIR}/cfg/server.cfg"
    elif [ -n "${DATA_DIR:-}" ]; then
        printf '%s' "${DATA_DIR}/cfg/server.cfg"
    else
        printf '%s' "${RUN_HOME}/.config/Necesse/cfg/server.cfg"
    fi
}

# Put the finished temp file in place of server.cfg. A server.cfg that is itself a bind mount
# (karyeet-style compose: ./server.cfg:/root/.config/Necesse/cfg/server.cfg) cannot be renamed over,
# so it is rewritten in place; if that write fails (read-only mount) the container refuses to start
# rather than run with a password other than the configured one.
install_cfg() {
    src="$1"
    dest="$2"
    real="$(readlink -f "${dest}")"
    if is_mount_point "${real}"; then
        if ! cat "${src}" > "${dest}" 2>/dev/null; then
            rm -f "${src}"
            echo "${dest} is the single-file mount ${real}, and it cannot be written (read-only mount?), so the join password cannot be applied to it. Mount it writable, or mount the directory instead (./cfg:$(dirname "${real}")). Refusing to start rather than run with a password other than the configured one." >&2
            exit 1
        fi
        rm -f "${src}"
        chmod 600 "${dest}" 2>/dev/null || true
        if is_root; then
            chown "${RUN_USER}:${RUN_GROUP}" "${dest}" 2>/dev/null || true
        fi
    else
        chmod 600 "${src}"
        if is_root; then
            chown "${RUN_USER}:${RUN_GROUP}" "${src}"
        fi
        mv -f "${src}" "${dest}"
    fi
}

# Rewrite the `password` field every start, blank included: the game keeps whatever the file says,
# so a password removed from the environment must also be removed from the file.
write_password_to_cfg() {
    cfg="$(server_cfg_path)"
    cfg_dir="$(dirname "${cfg}")"
    if [ ! -d "${cfg_dir}" ]; then
        # First start on an empty bind mount: create cfg/ as the run user, or the game cannot write settings.cfg next to it.
        mkdir -p "${cfg_dir}"
        if is_root; then
            chown "${RUN_USER}:${RUN_GROUP}" "${cfg_dir}"
        fi
    fi
    tmp="${cfg}.tmp.$$"

    if [ ! -f "${cfg}" ]; then
        # First start: seed the file with the game's own defaults (verbatim from what build 24926481
        # writes) so the loader finds every key; a password-only file makes it warn on every start.
        # Values the entrypoint passes on the command line (port, slots, ...) override these anyway.
        cat > "${tmp}" <<'CFG'
SERVER = {
	port = 14159, // [0 - 65535] Server default port
	slots = 10, // [1 - 250] Server default slots
	password = , // Leave blank for no password
	maxClientLatencySeconds = 30,
	pauseWhenEmpty = true,
	strictServerAuthority = false, // If true, server will be much more strict about what clients can do. It is strongly recommended to ONLY have this enabled if absolutely necessary
	logging = true, // If true, will create log files for each server start
	language = en,
	unloadLevelsCooldown = 30, // The number of seconds a level will stay loaded after the last player has left it
	droppedItemsLifeMinutes = 0, // Minutes that dropped items will stay in the world. 0 or less for indefinite
	unloadSettlements = false, // If the server should unload player settlements or keep them loaded
	maxSettlementsPerPlayer = -1, // The maximum amount of settlements per player. -1 or less means infinite
	maxSettlersPerSettlement = -1, // The maximum amount of settlers per settlement. -1 or less means infinite
	zipSaves = true, // If true, will create new saves uncompressed
	MOTD =  // Message of the day
}
CFG
        chmod 600 "${tmp}"
        if is_root; then
            chown "${RUN_USER}:${RUN_GROUP}" "${tmp}"
        fi
        mv -f "${tmp}" "${cfg}"
    fi

    if ! grep -q '^[[:space:]]*password[[:space:]]*=' "${cfg}"; then
        if ! grep -q '^[[:space:]]*SERVER[[:space:]]*=[[:space:]]*{' "${cfg}"; then
            echo "${cfg} has no 'password' field and no 'SERVER = {' block to add one to; refusing to start." >&2
            exit 1
        fi
        # Custom settings file without the key: add it right after the block opener.
        awk '{ print } /^[[:space:]]*SERVER[[:space:]]*=[[:space:]]*\{/ && !done { print "\tpassword = , // Leave blank for no password"; done = 1 }' "${cfg}" > "${tmp}"
        install_cfg "${tmp}" "${cfg}"
    fi

    # A legacy layout's server.cfg is the migrant's source of truth. If it already carries a password
    # and none is configured here, blanking it would open the server without anyone asking for that.
    if [ "${CFG_SHIMMED}" -eq 1 ] && [ -z "${RESOLVED_PASSWORD}" ]; then
        existing="$(sed -n 's/^[[:space:]]*password[[:space:]]*=[[:space:]]*\([^,]*\),.*/\1/p' "${cfg}" | head -n 1 | sed 's/[[:space:]]*$//')"
        if [ -n "${existing}" ]; then
            echo "$(readlink -f "${cfg}") carries a join password, but neither SERVER_PASSWORD nor SERVER_PASSWORD_FILE (nor an alias such as PASSWORD or password) is set. This image writes the configured password into that file on every start, which would open the server. Set SERVER_PASSWORD (to that password or a new one), or blank the password field in the file to run open on purpose. Refusing to start." >&2
            exit 1
        fi
    fi

    # Replace the value in place, keeping the trailing comment. The value travels through the
    # environment rather than -v so awk does not interpret backslashes in it.
    NECESSE_CFG_PASSWORD="${RESOLVED_PASSWORD}" awk '
        /^[[:space:]]*password[[:space:]]*=/ && !done {
            comment = ""
            if (match($0, /\/\/.*$/)) { comment = " " substr($0, RSTART) }
            print "\tpassword = " ENVIRON["NECESSE_CFG_PASSWORD"] "," comment
            done = 1
            next
        }
        { print }' "${cfg}" > "${tmp}"

    install_cfg "${tmp}" "${cfg}"
}

# --- Steam Workshop mods -----------------------------------------------------------------------
# Two ways to say which Workshop items the server runs; the union of both is fetched.
#   MODS_COLLECTION: one Workshop collection id. Resolved at every container start through the
#     public GetCollectionDetails endpoint (no key, no login) into the ids it holds, so adding or
#     removing a mod is an edit in the Steam client plus a container restart: no .env edit, no
#     recreate. The resolved ids are kept in <datadir>/ws-collection.txt as last-known-good, and a
#     Steam Web API outage falls back to that file so the mods hash does not change and players
#     are not locked out. Nested collections are not followed. A collection that resolves to no
#     file items is refused: that is a wrong id, not a request to run unmodded.
#   MODS_WORKSHOP: a comma-separated list of item ids, for people who do not want a collection.
# Before the first server launch each id is fetched anonymously with DepotDownloader (-pubfile) and the
# single jar it contains is copied FLAT into <datadir>/mods as ws-<id>-<OriginalName>.jar: the game
# only loads bare jars from that directory, and the download itself lands outside the bind mount,
# so it would vanish on recreate. Jars carrying the ws- prefix are managed: on every start the
# ones whose id is no longer listed are deleted, and that is the only deletion this script ever
# performs. Anything else in mods/ is left alone. Resolution and fetch run once per container
# start, never while Server.jar is running and not on auto-update restarts. With both variables
# empty mods/ is left untouched (2.1.0 behaviour).
MODS_WORKSHOP_IDS=""
MODS_COLLECTION_IDS=""
# Override only to exercise the failure paths in a test; not a user-facing setting.
STEAM_API_BASE="${MODS_STEAM_API_BASE:-https://api.steampowered.com}"

mods_dir() {
    if [ -n "${DATA_DIR:-}" ]; then
        printf '%s' "${DATA_DIR}/mods"
    else
        printf '%s' "${RUN_HOME}/.config/Necesse/mods"
    fi
}

# Default on: a partial mod set changes the mods hash and silently locks every player out, which is
# worse than not starting.
mods_fail_fast() {
    flag="$(lowercase "${MODS_FAIL_FAST:-true}")"
    [ "${flag}" != "false" ] && [ "${flag}" != "0" ] && [ "${flag}" != "no" ]
}

# Cheap checks first, so a bad list or a LOCAL_DIR conflict fails before the network is touched.
validate_workshop_config() {
    MODS_WORKSHOP_IDS=""
    if [ -z "${MODS_WORKSHOP:-}" ] && [ -z "${MODS_COLLECTION:-}" ]; then
        return
    fi

    local_dir_flag="$(lowercase "${LOCAL_DIR:-0}")"
    if [ "$local_dir_flag" = "1" ] || [ "$local_dir_flag" = "true" ]; then
        echo "MODS_COLLECTION/MODS_WORKSHOP cannot be combined with LOCAL_DIR=1: with -localdir the game loads mods from ${APP_DIR}/mods inside the image, not from the data directory, so managed jars would not persist. Refusing to start." >&2
        exit 1
    fi

    case "${MODS_COLLECTION:-}" in
        *[!0-9]*)
            echo "MODS_COLLECTION '${MODS_COLLECTION}' is not a single numeric Steam Workshop collection id (the number in the collection's URL); refusing to start." >&2
            exit 1
            ;;
    esac

    # shellcheck disable=SC2086
    for id in $(printf '%s' "${MODS_WORKSHOP:-}" | tr ',' ' '); do
        case "${id}" in
            *[!0-9]*)
                echo "MODS_WORKSHOP entry '${id}' is not a numeric Steam Workshop item id; refusing to start." >&2
                exit 1
                ;;
        esac
        add_workshop_id "${id}"
    done
}

add_workshop_id() {
    case " ${MODS_WORKSHOP_IDS} " in
        *" $1 "*) ;;
        *) MODS_WORKSHOP_IDS="${MODS_WORKSHOP_IDS}${MODS_WORKSHOP_IDS:+ }$1" ;;
    esac
}

collection_cache_path() {
    dir="$(mods_dir)"
    printf '%s' "${dir%/mods}/ws-collection.txt"
}

# POST to the Steam Web API. Prints the body on success. On any transport or HTTP failure prints
# nothing, returns non-zero and leaves the reason (curl's stderr) in STEAM_API_ERR_FILE for the
# caller: this runs inside a command substitution, so a variable could not carry it back.
STEAM_API_ERR_FILE="/tmp/necesse-steam-api-err"
steam_api_post() {
    if ! curl -sS -f --max-time 30 --retry 2 --retry-delay 3 \
            -X POST --data "$2" "${STEAM_API_BASE}$1" 2>"${STEAM_API_ERR_FILE}"; then
        return 1
    fi
    rm -f "${STEAM_API_ERR_FILE}"
}

steam_api_error() {
    if [ -s "${STEAM_API_ERR_FILE}" ]; then
        head -n 1 "${STEAM_API_ERR_FILE}" | sed 's/^curl: ([0-9]*) //; s/ *$//'
    else
        printf 'request failed'
    fi
    rm -f "${STEAM_API_ERR_FILE}"
}

# Resolve MODS_COLLECTION into MODS_COLLECTION_IDS and merge them into MODS_WORKSHOP_IDS.
# Transport/API errors are "resolution failed" (cache fallback, else MODS_FAIL_FAST decides);
# a definite answer that the id is wrong (not found, not public, no file items) is refused outright.
resolve_workshop_collection() {
    MODS_COLLECTION_IDS=""
    if [ -z "${MODS_COLLECTION:-}" ]; then
        return
    fi

    cache="$(collection_cache_path)"
    echo "Workshop collection: resolving ${MODS_COLLECTION} through the public Steam Web API..."
    failure=""
    body=""
    if ! body="$(steam_api_post /ISteamRemoteStorage/GetCollectionDetails/v1/ "collectioncount=1&publishedfileids[0]=${MODS_COLLECTION}")"; then
        failure="$(steam_api_error)"
    elif ! printf '%s' "${body}" | grep -q '"response":{"result":1'; then
        failure="unexpected API response: $(printf '%s' "${body}" | head -c 200)"
    else
        # The collection's own entry: {"publishedfileid":"<id>","result":N,"children":[...]}.
        # result 1 = found; 9 = no such public collection.
        coll_result="$(printf '%s' "${body}" | tr '{' '\n' | grep "\"publishedfileid\":\"${MODS_COLLECTION}\"" | grep -v '"filetype"' | sed -n 's/.*"result":\([0-9]*\).*/\1/p' | head -n 1)"
        if [ "${coll_result}" != "1" ]; then
            echo "Workshop collection: ${MODS_COLLECTION} is not a public Steam Workshop collection (API result ${coll_result:-missing}); check the id in the collection's URL. Refusing to start." >&2
            exit 1
        fi

        # children[]: {"publishedfileid":"<id>","sortorder":n,"filetype":t}; 0 = file item, 2 = collection.
        children="$(printf '%s' "${body}" | tr '{' '\n' | awk '
            /"filetype"/ {
                id = ""; type = ""
                if (match($0, /"publishedfileid":"[0-9]+"/)) { id = substr($0, RSTART + 19, RLENGTH - 20) }
                if (match($0, /"filetype":[0-9]+/)) { type = substr($0, RSTART + 11, RLENGTH - 11) }
                if (id != "" && type != "") { print id ":" type }
            }')"
        for child in ${children}; do
            cid="${child%%:*}"
            ctype="${child#*:}"
            case "${ctype}" in
                0)
                    case " ${MODS_COLLECTION_IDS} " in
                        *" ${cid} "*) ;;
                        *) MODS_COLLECTION_IDS="${MODS_COLLECTION_IDS}${MODS_COLLECTION_IDS:+ }${cid}" ;;
                    esac
                    ;;
                2)
                    echo "Workshop collection: WARNING: ${cid} inside ${MODS_COLLECTION} is itself a collection; nested collections are not followed, so its items are skipped. Add them to ${MODS_COLLECTION} directly." >&2
                    ;;
                *)
                    echo "Workshop collection: WARNING: ${cid} inside ${MODS_COLLECTION} has filetype ${ctype}, not a Workshop file item; skipped." >&2
                    ;;
            esac
        done

        if [ -z "${MODS_COLLECTION_IDS}" ]; then
            echo "Workshop collection: ${MODS_COLLECTION} holds no Workshop file items. That is almost certainly the wrong id (or an empty collection); to run without mods unset MODS_COLLECTION instead. Refusing to start." >&2
            exit 1
        fi
    fi

    if [ -n "${failure}" ]; then
        if [ -s "${cache}" ]; then
            MODS_COLLECTION_IDS="$(grep -E '^[0-9]+$' "${cache}" | tr '\n' ' ' | sed 's/ *$//')"
            echo "Workshop collection: WARNING: could not resolve ${MODS_COLLECTION} (${failure}); using the last-known-good ${cache##*/} ($(printf '%s' "${MODS_COLLECTION_IDS}" | wc -w) item(s) from $(date -u -r "${cache}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'an earlier start')). The mod set is unchanged from the last successful resolution." >&2
        elif mods_fail_fast; then
            echo "Workshop collection: could not resolve ${MODS_COLLECTION} (${failure}) and there is no previous ${cache##*/} to fall back to; refusing to start (MODS_FAIL_FAST=true)." >&2
            exit 1
        else
            echo "Workshop collection: WARNING: could not resolve ${MODS_COLLECTION} (${failure}) and there is no previous ${cache##*/} to fall back to; starting with MODS_WORKSHOP ids only (MODS_FAIL_FAST=false)." >&2
        fi
    else
        count="$(printf '%s' "${MODS_COLLECTION_IDS}" | wc -w)"
        echo "Workshop collection: ${MODS_COLLECTION} resolved to ${count} item(s): ${MODS_COLLECTION_IDS}."
        cache_dir="$(dirname "${cache}")"
        if [ ! -d "${cache_dir}" ]; then
            mkdir -p "${cache_dir}"
            if is_root; then
                chown "${RUN_USER}:${RUN_GROUP}" "${cache_dir}"
            fi
        fi
        tmp="${cache}.tmp.$$"
        # shellcheck disable=SC2086
        printf '%s\n' ${MODS_COLLECTION_IDS} > "${tmp}"
        chmod 600 "${tmp}"
        if is_root; then
            chown "${RUN_USER}:${RUN_GROUP}" "${tmp}"
        fi
        mv -f "${tmp}" "${cache}"
    fi

    for cid in ${MODS_COLLECTION_IDS}; do
        add_workshop_id "${cid}"
    done
}

# The manifest and timeupdated values ws-manifest.txt shows per item come from Steam's public
# GetPublishedFileDetails endpoint (no key, no login), one request for all listed ids. SteamCMD used
# to record the same two values in appworkshop_<app>.acf; DepotDownloader keeps no such file. This is
# metadata only: if the request fails the fetch still runs and the manifest carries "-" for both.
WORKSHOP_DETAILS=""
fetch_workshop_item_details() {
    WORKSHOP_DETAILS=""
    [ -n "${MODS_WORKSHOP_IDS}" ] || return 0
    data="itemcount=$(printf '%s' "${MODS_WORKSHOP_IDS}" | wc -w | tr -d ' ')"
    i=0
    for id in ${MODS_WORKSHOP_IDS}; do
        data="${data}&publishedfileids[${i}]=${id}"
        i=$((i + 1))
    done
    if ! WORKSHOP_DETAILS="$(steam_api_post /ISteamRemoteStorage/GetPublishedFileDetails/v1/ "${data}")"; then
        echo "Workshop mods: WARNING: could not read the item details from the Steam Web API ($(steam_api_error)); ws-manifest.txt will show - for manifest and timeupdated." >&2
        WORKSHOP_DETAILS=""
    fi
}

# One numeric field of one item from that response, e.g. workshop_detail <id> hcontent_file (the item's
# manifest id, a quoted string) or workshop_detail <id> time_updated (a bare number). The item's entry
# starts at its publishedfileid and ends where the next item's begins.
workshop_detail() {
    [ -n "${WORKSHOP_DETAILS}" ] || return 0
    printf '%s' "${WORKSHOP_DETAILS}" | tr -d '\n' \
        | sed -n "s/.*\"publishedfileid\":\"$1\",\(.*\)/\1/p" | sed 's/"publishedfileid":.*//' \
        | grep -o "\"$2\":\"\{0,1\}[0-9][0-9]*" | head -n 1 | grep -o '[0-9]*$'
}

# ws-manifest.txt: one line per listed id so the operator can see which Workshop revision is live.
# It lives beside mods/, not inside it: the game scans every file in mods/ and logs a WARN for each
# non-jar it finds there.
write_workshop_manifest() {
    dir="$1"
    failed_ids="$2"
    manifest="${dir%/mods}/ws-manifest.txt"
    tmp="${manifest}.tmp.$$"
    : > "${tmp}"
    for id in ${MODS_WORKSHOP_IDS}; do
        jar="$(find "${dir}" -maxdepth 1 -type f -name "ws-${id}-*.jar" | head -n 1)"
        title="-"
        if [ -n "${jar}" ]; then
            title="${jar##*/}"
            title="${title#ws-"${id}"-}"
        fi
        status="ok"
        case " ${failed_ids} " in
            *" ${id} "*) status="failed" ;;
        esac
        item_manifest="$(workshop_detail "${id}" hcontent_file)"
        item_time="$(workshop_detail "${id}" time_updated)"
        printf '%s\t%s\tmanifest=%s\ttimeupdated=%s\tstatus=%s\n' \
            "${id}" "${title}" "${item_manifest:--}" "${item_time:--}" "${status}" >> "${tmp}"
    done
    chmod 600 "${tmp}"
    if is_root; then
        chown "${RUN_USER}:${RUN_GROUP}" "${tmp}"
    fi
    mv -f "${tmp}" "${manifest}"
}

fetch_workshop_mods() {
    if [ -z "${MODS_WORKSHOP_IDS}" ]; then
        return
    fi

    dir="$(mods_dir)"
    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}"
        chmod 700 "${dir}"
        if is_root; then
            chown "${RUN_USER}:${RUN_GROUP}" "${dir}"
        fi
    fi
    # Created as the run user so that every parent it makes belongs to that user too: DepotDownloader
    # keeps its account settings in ~/.local/share/IsolatedStorage, next to this directory, and aborts
    # when it cannot create that.
    if [ ! -d "${WORKSHOP_DIR}" ]; then
        run_as_user mkdir -p "${WORKSHOP_DIR}"
    fi
    fetch_workshop_item_details

    echo "Workshop mods: fetching item(s) ${MODS_WORKSHOP_IDS} from app ${WORKSHOP_APP_ID} with an anonymous login..."
    failed=""
    for id in ${MODS_WORKSHOP_IDS}; do
        started="$(date +%s)"
        log="/tmp/necesse-workshop-${id}.log"
        item_dir="${WORKSHOP_DIR}/${id}"
        # A fresh directory per fetch: DepotDownloader never deletes files, so a jar the author renamed
        # would otherwise sit next to the new one. Its output is shown as usual, like the app update's.
        rm -rf "${item_dir}"
        run_as_user "${DEPOTDOWNLOADER_BIN}" -app "${WORKSHOP_APP_ID}" -pubfile "${id}" -dir "${item_dir}" 2>&1 | tee "${log}" || true
        # DepotDownloader exits 0 even when the item does not exist ("Unable to locate manifest ID for
        # published file <id>"), so the total it prints after a completed download is the reliable signal.
        if ! grep -q '^Total downloaded: ' "${log}"; then
            reason="$(grep -v -e '^Connecting to Steam3' -e '^Logging anonymously' -e '^No username given' -e '^Using Steam3' -e '^Disconnected from Steam' -e '^$' "${log}" | tail -n 1)"
            rm -f "${log}"
            echo "Workshop mods: item ${id} failed to download${reason:+ (${reason})}." >&2
            failed="${failed}${failed:+ }${id}"
            continue
        fi
        rm -f "${log}"

        jar_count="$(find "${item_dir}" -maxdepth 1 -type f -name '*.jar' | wc -l)"
        if [ "${jar_count}" -ne 1 ]; then
            echo "Workshop mods: item ${id} downloaded but holds ${jar_count} .jar files where exactly one was expected; not a loadable Necesse mod." >&2
            failed="${failed}${failed:+ }${id}"
            continue
        fi
        src="$(find "${item_dir}" -maxdepth 1 -type f -name '*.jar')"
        name="${src##*/}"
        dest="${dir}/ws-${id}-${name}"

        # The author renamed or re-versioned the jar: drop the managed copy under the old name.
        for old in "${dir}/ws-${id}-"*.jar; do
            [ -e "${old}" ] || continue
            [ "${old}" = "${dest}" ] && continue
            echo "Workshop mods: item ${id} is now ${name}; removing ${old##*/}."
            rm -f "${old}"
        done

        if [ -f "${dest}" ] && cmp -s "${src}" "${dest}"; then
            echo "Workshop mods: item ${id} unchanged (${dest##*/}), $(( $(date +%s) - started ))s."
        else
            tmp="${dest}.tmp.$$"
            cp "${src}" "${tmp}"
            chmod 600 "${tmp}"
            if is_root; then
                chown "${RUN_USER}:${RUN_GROUP}" "${tmp}"
            fi
            mv -f "${tmp}" "${dest}"
            echo "Workshop mods: item ${id} installed as ${dest##*/}, $(( $(date +%s) - started ))s."
        fi
    done

    if [ -n "${failed}" ]; then
        if mods_fail_fast; then
            echo "Workshop mods: item(s) ${failed} could not be fetched; refusing to start with a partial mod set (MODS_FAIL_FAST=true). A missing mod changes the server's mods hash and locks every subscribed player out." >&2
            exit 1
        fi
        echo "Workshop mods: WARNING: item(s) ${failed} could not be fetched; starting anyway with what is installed (MODS_FAIL_FAST=false)." >&2
    fi

    # Managed jars whose id is no longer listed are deleted. Only the ws-<digits>- form is touched.
    for jar in "${dir}"/ws-*.jar; do
        [ -e "${jar}" ] || continue
        base="${jar##*/}"
        jid="${base#ws-}"
        jid="${jid%%-*}"
        case "${jid}" in
            ''|*[!0-9]*) continue ;;
        esac
        case " ${MODS_WORKSHOP_IDS} " in
            *" ${jid} "*) ;;
            *)
                echo "Workshop mods: removing ${base} (item ${jid} is no longer listed)."
                rm -f "${jar}"
                ;;
        esac
    done

    write_workshop_manifest "${dir}" "${failed}"
    echo "Workshop mods: done; see ${dir%/mods}/ws-manifest.txt."
}

# --- Game files: DepotDownloader -----------------------------------------------------------------
# "<depot> <manifest>" lines from a DepotDownloader log: the line it prints for every depot it processes,
# whether it downloads the manifest ("Got manifest request code for depot D from app A, manifest M, ...")
# or already has it cached ("Already have manifest M for depot D."), with -manifest-only and with a
# download alike. The Dockerfile's game stage applies the same two patterns to record the image's baseline.
manifests_from_log() {
    sed -n -e 's/^Got manifest request code for depot \([0-9]*\) from app [0-9]*, manifest \([0-9]*\),.*/\1 \2/p' \
           -e 's/^Already have manifest \([0-9]*\) for depot \([0-9]*\)\..*/\2 \1/p' "$1" | sort -u
}

# "1006:6403079453713498174 1169375:6374287384649212625", for log lines.
manifests_line() {
    printf '%s\n' "$1" | tr ' ' ':' | tr '\n' ' ' | sed 's/ $//'
}

installed_manifests() {
    if [ -f "${INSTALLED_MANIFESTS_FILE}" ]; then
        sort -u "${INSTALLED_MANIFESTS_FILE}"
    fi
}

# What Steam serves for the app right now: a -manifest-only run into a scratch directory, which fetches
# the manifests (a few hundred KB) and no game files. Prints nothing when Steam cannot be reached.
remote_manifests() {
    scratch="/tmp/necesse-manifest-check"
    log="${scratch}.log"
    rm -rf "${scratch}" "${log}"
    if ! run_as_user "${DEPOTDOWNLOADER_BIN}" -app "${APP_ID}" -os linux -osarch 64 -manifest-only -dir "${scratch}" >"${log}" 2>&1; then
        rm -rf "${scratch}" "${log}"
        return 1
    fi
    manifests_from_log "${log}"
    rm -rf "${scratch}" "${log}"
}

# After a successful download: record what it installed, from its log, for the next check.
record_installed_manifests() {
    found="$(manifests_from_log "$1")"
    if [ -z "${found}" ]; then
        echo "WARN: could not read the depot manifests from DepotDownloader's output; the auto-update baseline is left as it was." >&2
        return
    fi
    tmp="${INSTALLED_MANIFESTS_FILE}.tmp.$$"
    printf '%s\n' "${found}" > "${tmp}"
    if is_root; then
        chown "${RUN_USER}:${RUN_GROUP}" "${tmp}"
    fi
    mv -f "${tmp}" "${INSTALLED_MANIFESTS_FILE}"
}

# DepotDownloader creates a directory for every path in the manifest, the two excluded ones included.
prune_excluded_dirs() {
    for d in "${APP_DIR}/jre" "${APP_DIR}/linux64"; do
        if [ -d "${d}" ]; then
            find "${d}" -depth -type d -empty -delete 2>/dev/null || true
        fi
    done
}

write_depot_filelist() {
    printf '%s\n' "${DEPOT_FILELIST_RULE}" > "${DEPOT_FILELIST}"
    chmod 644 "${DEPOT_FILELIST}"
}

calculate_auto_update_interval() {
    interval="${AUTO_UPDATE_INTERVAL_MINUTES:-0}"
    if [ -z "${interval}" ]; then
        interval=0
    fi

    if printf '%s' "${interval}" | grep -Eq '^[0-9]+$'; then
        AUTO_UPDATE_INTERVAL_MINUTES_NORMALIZED="${interval}"
        AUTO_UPDATE_INTERVAL_SECONDS=$((interval * 60))
    else
        echo "AUTO_UPDATE_INTERVAL_MINUTES must be numeric; disabling auto update." >&2
        AUTO_UPDATE_INTERVAL_MINUTES_NORMALIZED=0
        AUTO_UPDATE_INTERVAL_SECONDS=0
    fi
}

check_for_remote_update() {
    current="$(installed_manifests || true)"
    remote="$(remote_manifests || true)"

    if [ -z "${remote}" ]; then
        echo "Auto-update: unable to determine the remote build (DepotDownloader manifest check failed)." >&2
        return 1
    fi

    if [ -z "${current}" ]; then
        echo "Auto-update: no local build found; treating as update required."
        return 0
    fi

    if [ "${remote}" != "${current}" ]; then
        echo "Auto-update: new build detected (local $(manifests_line "${current}"), remote $(manifests_line "${remote}"))."
        return 0
    fi

    return 1
}

stop_auto_update_monitor() {
    if [ -n "${AUTO_UPDATE_MONITOR_PID}" ]; then
        if kill -0 "${AUTO_UPDATE_MONITOR_PID}" 2>/dev/null; then
            kill "${AUTO_UPDATE_MONITOR_PID}" 2>/dev/null || true
        fi
        wait "${AUTO_UPDATE_MONITOR_PID}" 2>/dev/null || true
        AUTO_UPDATE_MONITOR_PID=""
    fi
}

start_auto_update_monitor() {
    calculate_auto_update_interval
    seconds="${AUTO_UPDATE_INTERVAL_SECONDS}"
    if [ "${seconds}" -le 0 ]; then
        return
    fi

    echo "Auto-update: enabled; checking for new builds every ${AUTO_UPDATE_INTERVAL_MINUTES_NORMALIZED} minute(s)."

    # The monitor keeps fd 3 (console) but must not hold the output FIFO's write end, or the
    # redactor would never see EOF at shutdown.
    (
        while true; do
            sleep "${seconds}"
            if check_for_remote_update; then
                touch "${AUTO_UPDATE_FLAG_FILE}"
                echo "Auto-update: stopping server to apply latest build."
                request_server_stop "${SERVER_PID}"
                exit 0
            fi
        done
    ) 4>&- &
    AUTO_UPDATE_MONITOR_PID=$!
}

open_console() {
    rm -f "${CONSOLE_FIFO}"
    mkfifo -m 600 "${CONSOLE_FIFO}"
    # Read-write so the open never blocks and the server never sees EOF on stdin.
    exec 3<>"${CONSOLE_FIFO}"
}

# One redactor lives for the whole container: fd 4 keeps the FIFO open read-write so the reader
# survives server restarts (auto-update) and only sees EOF once close_output drops fd 4.
open_output() {
    rm -f "${OUTPUT_FIFO}"
    mkfifo -m 600 "${OUTPUT_FIFO}"
    exec 4<>"${OUTPUT_FIFO}"
    NECESSE_REDACT_SECRET="${RESOLVED_PASSWORD}" bash "${APP_DIR}/redact.sh" <"${OUTPUT_FIFO}" 3>&- 4>&- &
    REDACTOR_PID=$!
}

# Call only after the server has exited: closing fd 4 lets the redactor drain and finish.
close_output() {
    exec 4>&-
    if [ -n "${REDACTOR_PID}" ]; then
        wait "${REDACTOR_PID}" 2>/dev/null || true
        REDACTOR_PID=""
    fi
}

send_console() {
    printf '%s\n' "$1" >&3
}

# Ask the server to save and exit via its console; fall back to SIGTERM after STOP_TIMEOUT_SECONDS.
# Takes the PID to watch so the auto-update monitor (a subshell) can reuse it.
request_server_stop() {
    pid="$1"
    if ! kill -0 "${pid}" 2>/dev/null; then
        return
    fi

    echo "Sending console 'stop' so the world is saved (timeout ${STOP_TIMEOUT_SECONDS}s)..."
    send_console stop
    waited=0
    while kill -0 "${pid}" 2>/dev/null && [ "${waited}" -lt "${STOP_TIMEOUT_SECONDS}" ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "${pid}" 2>/dev/null; then
        echo "Server did not exit within ${STOP_TIMEOUT_SECONDS}s; sending SIGTERM." >&2
        kill "${pid}" 2>/dev/null || true
    fi
}

stop_server() {
    if [ -n "${SERVER_PID}" ]; then
        request_server_stop "${SERVER_PID}"
        wait "${SERVER_PID}" 2>/dev/null || true
        SERVER_PID=""
    fi
}

launch_server() {
    if [ ! -x "${JAVA_BIN}" ]; then
        echo "Java runtime not found at ${JAVA_BIN}; the image's JRE is ${JAVA_HOME:-/opt/java/openjdk}/bin/java. Set JAVA_BIN to the JRE to launch with, or unset it." >&2
        exit 1
    fi

    write_password_to_cfg

    set -- "${JAVA_BIN}"

    if [ -n "${JAVA_OPTS:-}" ]; then
        # shellcheck disable=SC2086
        for opt in ${JAVA_OPTS}; do
            set -- "$@" "$opt"
        done
    fi

    set -- "$@" -jar Server.jar -nogui

    local_dir_flag="$(lowercase "${LOCAL_DIR:-0}")"
    if [ "$local_dir_flag" = "1" ] || [ "$local_dir_flag" = "true" ]; then
        set -- "$@" -localdir
    fi

    if [ -n "${DATA_DIR:-}" ]; then
        mkdir -p "${DATA_DIR}"
        set -- "$@" -datadir "${DATA_DIR}"
    fi

    if [ -n "${LOGS_DIR:-}" ]; then
        mkdir -p "${LOGS_DIR}"
        set -- "$@" -logs "${LOGS_DIR}"
    fi

    if [ -n "${WORLD_NAME:-}" ]; then
        set -- "$@" -world "${WORLD_NAME}"
    fi

    if [ -n "${SERVER_PORT:-}" ]; then
        set -- "$@" -port "${SERVER_PORT}"
    fi

    if [ -n "${SERVER_SLOTS:-}" ]; then
        set -- "$@" -slots "${SERVER_SLOTS}"
    fi

    if [ -n "${SERVER_OWNER:-}" ]; then
        set -- "$@" -owner "${SERVER_OWNER}"
    fi

    if [ -n "${SERVER_MOTD:-}" ]; then
        set -- "$@" -motd "${SERVER_MOTD}"
    fi

    # No -password here: the game reads it from server.cfg (see write_password_to_cfg).

    if [ -n "${PAUSE_WHEN_EMPTY:-}" ]; then
        set -- "$@" -pausewhenempty "${PAUSE_WHEN_EMPTY}"
    fi

    if [ -n "${GIVE_CLIENTS_POWER:-}" ]; then
        set -- "$@" -giveclientspower "${GIVE_CLIENTS_POWER}"
    fi

    if [ -n "${ENABLE_LOGGING:-}" ]; then
        set -- "$@" -logging "${ENABLE_LOGGING}"
    fi

    if [ -n "${ZIP_SAVES:-}" ]; then
        set -- "$@" -zipsaves "${ZIP_SAVES}"
    fi

    if [ -n "${SERVER_LANGUAGE:-}" ]; then
        set -- "$@" -language "${SERVER_LANGUAGE}"
    fi

    if [ -n "${SETTINGS_FILE:-}" ]; then
        set -- "$@" -settings "${SETTINGS_FILE}"
    fi

    if [ -n "${BIND_IP:-}" ]; then
        set -- "$@" -ip "${BIND_IP}"
    fi

    if [ -n "${MAX_CLIENT_LATENCY:-}" ]; then
        set -- "$@" -maxlatency "${MAX_CLIENT_LATENCY}"
    fi

    echo "Starting Necesse server with command:"
    printf '  %s' "$@"
    printf '\n\n'

    # stdin: the console FIFO. stdout/stderr: the output FIFO feeding redact.sh. umask 077 makes
    # every file the game creates (logs, saves, cfg) 0600. The password variables (and their
    # aliases) are dropped from the environment, and the child closes fds 3/4 so it holds neither
    # FIFO's spare end.
    (
        umask 077
        if is_root; then
            exec gosu "${RUN_USER}:${RUN_GROUP}" env -u SERVER_PASSWORD -u SERVER_PASSWORD_FILE -u PASSWORD -u password HOME="${RUN_HOME}" "$@"
        else
            exec env -u SERVER_PASSWORD -u SERVER_PASSWORD_FILE -u PASSWORD -u password "$@"
        fi
    ) <&3 >"${OUTPUT_FIFO}" 2>&1 3>&- 4>&- &
    SERVER_PID=$!
}

wait_for_server() {
    if [ -n "${SERVER_PID}" ]; then
        if wait "${SERVER_PID}"; then
            SERVER_EXIT_CODE=0
        else
            SERVER_EXIT_CODE=$?
        fi
        SERVER_PID=""
    fi
}

handle_exit() {
    trap - INT TERM
    stop_auto_update_monitor
    stop_server
    close_output
    exit 0
}

maybe_update_server() {
    update_flag="$(lowercase "${UPDATE_ON_START:-false}")"

    if [ -f "${AUTO_UPDATE_FLAG_FILE}" ]; then
        update_flag="true"
    fi

    if [ ! -f "$APP_DIR/Server.jar" ] || [ "$update_flag" = "true" ]; then
        echo "Running DepotDownloader to install or update Necesse (anonymous, app ${APP_ID})..."
        write_depot_filelist
        log="/tmp/necesse-update.log"
        rc_file="/tmp/necesse-update.rc"
        # The output is shown live and kept for the manifest record; the exit code travels through a
        # file because a POSIX shell has no pipefail. -validate re-checks the files already in place,
        # as SteamCMD's `app_update ... validate` did.
        { run_as_user "${DEPOTDOWNLOADER_BIN}" -app "${APP_ID}" -os linux -osarch 64 -dir "${APP_DIR}" \
              -filelist "${DEPOT_FILELIST}" -validate 2>&1; echo "$?" > "${rc_file}"; } | tee "${log}"
        result="$(cat "${rc_file}")"
        rm -f "${rc_file}"
        if [ "${result}" -eq 0 ] && grep -q '^Total downloaded: ' "${log}" && [ -f "$APP_DIR/Server.jar" ]; then
            record_installed_manifests "${log}"
            prune_excluded_dirs
            rm -f "${log}"
            echo "DepotDownloader run complete."
        else
            rm -f "${log}"
            [ "${result}" -ne 0 ] || result=1
            echo "DepotDownloader did not complete the download (exit code ${result}); its output is above."
            if [ -f "$APP_DIR/Server.jar" ]; then
                echo "Keeping existing server build; new files were not applied."
                rm -f "${AUTO_UPDATE_FLAG_FILE}"
                return
            fi

            echo "No existing server binaries found and DepotDownloader failed; aborting start."
            exit "${result}"
        fi
    fi

    rm -f "${AUTO_UPDATE_FLAG_FILE}"
}

main_loop() {
    while true; do
        SERVER_EXIT_CODE=0
        maybe_update_server
        launch_server
        start_auto_update_monitor
        wait_for_server
        stop_auto_update_monitor

        if [ -f "${AUTO_UPDATE_FLAG_FILE}" ]; then
            echo "Auto-update: restarting server with fresh binaries."
            continue
        fi

        close_output
        exit "${SERVER_EXIT_CODE}"
    done
}

trap 'handle_exit' INT TERM

apply_env_aliases
apply_defaults
adjust_permissions
link_legacy_mounts
detect_world
resolve_password
validate_workshop_config
resolve_workshop_collection
fetch_workshop_mods
open_console
open_output
main_loop
