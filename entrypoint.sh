#!/bin/sh
set -eu

# SteamCMD comes from the base image (ghcr.io/steamcmd/steamcmd): the `steamcmd` wrapper keeps
# per-user state under $HOME/.local/share/Steam. STEAMCMD_DIR only holds the update runscript.
STEAMCMD_DIR="/steamapps"
APP_DIR="/app"
APP_ID="1169370"
RUN_USER="${CONTAINER_USER:-necesse}"
RUN_GROUP="${CONTAINER_GROUP:-necesse}"
RUN_HOME="/home/${RUN_USER}"
# The Steam build of the dedicated server ships its own JRE (StartServer-nogui.sh uses ./jre/bin/java).
JAVA_BIN="${JAVA_BIN:-${APP_DIR}/jre/bin/java}"
AUTO_UPDATE_FLAG_FILE="/tmp/necesse-auto-update"
# The server only saves on the console `stop` command, not on SIGTERM (verified 2026-09-07: a plain
# SIGTERM exits in <1s without a save). Its stdin is a FIFO held open by this script, so a stop
# request can be typed into the console from the TERM trap and from the auto-update monitor.
CONSOLE_FIFO="/tmp/necesse-console"
# The server's stdout/stderr go through a second FIFO into redact.sh, which replaces the join
# password with **** before anything reaches the container log (the game prints it on start).
OUTPUT_FIFO="/tmp/necesse-output"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-50}"
# Steam Workshop items are published under the client app id, not the dedicated server's.
WORKSHOP_APP_ID="1169040"
WORKSHOP_STEAM_DIR="${RUN_HOME}/.local/share/Steam/steamapps/workshop"

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
        "${RUN_HOME}" \
        "${STEAMCMD_DIR}"
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
        mv -f "${tmp}" "${cfg}"
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

    chmod 600 "${tmp}"
    if is_root; then
        chown "${RUN_USER}:${RUN_GROUP}" "${tmp}"
    fi
    mv -f "${tmp}" "${cfg}"
}

# --- Steam Workshop mods -----------------------------------------------------------------------
# MODS_WORKSHOP is a comma-separated list of Workshop item ids. Before the first server launch each
# one is fetched with an anonymous SteamCMD login and the single jar it contains is copied FLAT into
# <datadir>/mods as ws-<id>-<OriginalName>.jar: the game only loads bare jars from that directory,
# and SteamCMD's own download lands outside the bind mount, so it would vanish on recreate.
# Jars carrying the ws- prefix are managed: on every start the ones whose id is no longer listed
# are deleted, and that is the only deletion this script ever performs. Anything else in mods/ is
# left alone. The fetch runs once per container start, never while Server.jar is running and not on
# auto-update restarts. An empty MODS_WORKSHOP leaves mods/ untouched (2.1.0 behaviour).
MODS_WORKSHOP_IDS=""

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

# Cheap checks first, so a bad list or a LOCAL_DIR conflict fails before SteamCMD is touched.
validate_workshop_config() {
    MODS_WORKSHOP_IDS=""
    if [ -z "${MODS_WORKSHOP:-}" ]; then
        return
    fi

    local_dir_flag="$(lowercase "${LOCAL_DIR:-0}")"
    if [ "$local_dir_flag" = "1" ] || [ "$local_dir_flag" = "true" ]; then
        echo "MODS_WORKSHOP cannot be combined with LOCAL_DIR=1: with -localdir the game loads mods from ${APP_DIR}/mods inside the image, not from the data directory, so managed jars would not persist. Refusing to start." >&2
        exit 1
    fi

    # shellcheck disable=SC2086
    for id in $(printf '%s' "${MODS_WORKSHOP}" | tr ',' ' '); do
        case "${id}" in
            *[!0-9]*)
                echo "MODS_WORKSHOP entry '${id}' is not a numeric Steam Workshop item id; refusing to start." >&2
                exit 1
                ;;
        esac
        case " ${MODS_WORKSHOP_IDS} " in
            *" ${id} "*) ;;
            *) MODS_WORKSHOP_IDS="${MODS_WORKSHOP_IDS}${MODS_WORKSHOP_IDS:+ }${id}" ;;
        esac
    done
}

# One field of one item from the WorkshopItemsInstalled block of appworkshop_<app>.acf.
workshop_acf_field() {
    acf="${WORKSHOP_STEAM_DIR}/appworkshop_${WORKSHOP_APP_ID}.acf"
    [ -f "${acf}" ] || return 0
    awk -v id="$1" -v field="$2" -F'"' '
        $2 == "WorkshopItemsInstalled" { installed = 1; next }
        installed && $2 == "WorkshopItemDetails" { installed = 0 }
        installed && !inside && $2 == id { inside = 1; next }
        inside && $2 == field { print $4; exit }
        inside && /^[[:space:]]*}/ { inside = 0 }
    ' "${acf}"
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
        item_manifest="$(workshop_acf_field "${id}" manifest)"
        item_time="$(workshop_acf_field "${id}" timeupdated)"
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
    content_root="${WORKSHOP_STEAM_DIR}/content/${WORKSHOP_APP_ID}"
    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}"
        chmod 700 "${dir}"
        if is_root; then
            chown "${RUN_USER}:${RUN_GROUP}" "${dir}"
        fi
    fi

    echo "Workshop mods: fetching item(s) ${MODS_WORKSHOP_IDS} from app ${WORKSHOP_APP_ID} with an anonymous login..."
    failed=""
    for id in ${MODS_WORKSHOP_IDS}; do
        started="$(date +%s)"
        log="/tmp/necesse-workshop-${id}.log"
        # SteamCMD exits 0 even when the download fails, so the success line is the only reliable
        # signal. Its output is shown as usual, like the app update's.
        run_as_user steamcmd +login anonymous +workshop_download_item "${WORKSHOP_APP_ID}" "${id}" +quit 2>&1 | tee "${log}" || true
        # SteamCMD's last line has no newline; start ours on a fresh one.
        echo
        if ! grep -q "Success. Downloaded item ${id} to" "${log}"; then
            reason="$(grep -o "ERROR! Download item ${id} failed ([^)]*)" "${log}" | head -n 1)"
            reason="${reason#"ERROR! Download item ${id} failed ("}"
            reason="${reason%)}"
            rm -f "${log}"
            echo "Workshop mods: item ${id} failed to download${reason:+ (${reason})}." >&2
            failed="${failed}${failed:+ }${id}"
            continue
        fi
        rm -f "${log}"

        jar_count="$(find "${content_root}/${id}" -maxdepth 1 -type f -name '*.jar' | wc -l)"
        if [ "${jar_count}" -ne 1 ]; then
            echo "Workshop mods: item ${id} downloaded but holds ${jar_count} .jar files where exactly one was expected; not a loadable Necesse mod." >&2
            failed="${failed}${failed:+ }${id}"
            continue
        fi
        src="$(find "${content_root}/${id}" -maxdepth 1 -type f -name '*.jar')"
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
                echo "Workshop mods: removing ${base} (item ${jid} is no longer in MODS_WORKSHOP)."
                rm -f "${jar}"
                ;;
        esac
    done

    write_workshop_manifest "${dir}" "${failed}"
    echo "Workshop mods: done; see ${dir%/mods}/ws-manifest.txt."
}

get_manifest_buildid() {
    # SteamCMD writes manifests into the install dir's steamapps folder when force_install_dir is used.
    # Fall back to the per-user SteamCMD root for older layouts or if users override directories.
    for manifest_path in \
        "${APP_DIR}/steamapps/appmanifest_${APP_ID}.acf" \
        "${RUN_HOME}/.local/share/Steam/steamapps/appmanifest_${APP_ID}.acf"
    do
        if [ -f "${manifest_path}" ]; then
            awk -F'"' '/"buildid"/ {print $4; exit}' "${manifest_path}"
            return
        fi
    done
}

fetch_remote_buildid() {
    run_as_user steamcmd \
        +login anonymous \
        +app_info_update 1 \
        +app_info_print "${APP_ID}" \
        +quit \
        | awk -F'"' '/"buildid"/ {print $4; exit}'
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
    current="$(get_manifest_buildid || true)"
    remote="$(fetch_remote_buildid || true)"

    if [ -z "${remote}" ]; then
        echo "Auto-update: unable to determine remote build ID." >&2
        return 1
    fi

    if [ -z "${current}" ]; then
        echo "Auto-update: no local build found; treating as update required."
        return 0
    fi

    if [ "${remote}" != "${current}" ]; then
        echo "Auto-update: new build detected (local ${current}, remote ${remote})."
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
        echo "Bundled JRE not found at ${JAVA_BIN}; the Steam build layout may have changed. Set JAVA_BIN to override." >&2
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
    # every file the game creates (logs, saves, cfg) 0600. The password variables are dropped from
    # the environment, and the child closes fds 3/4 so it holds neither FIFO's spare end.
    (
        umask 077
        if is_root; then
            exec gosu "${RUN_USER}:${RUN_GROUP}" env -u SERVER_PASSWORD -u SERVER_PASSWORD_FILE HOME="${RUN_HOME}" "$@"
        else
            exec env -u SERVER_PASSWORD -u SERVER_PASSWORD_FILE "$@"
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
        echo "Running SteamCMD to install or update Necesse..."
        if run_as_user steamcmd +runscript "$STEAMCMD_DIR/update_necesse.txt"; then
            echo "SteamCMD run complete."
        else
            result=$?
            echo "SteamCMD failed with exit code ${result}."
            if [ -f "$APP_DIR/Server.jar" ]; then
                echo "Keeping existing server build; new files were not applied."
                echo "Check ${RUN_HOME}/.local/share/Steam/logs/stderr.txt for SteamCMD details."
                rm -f "${AUTO_UPDATE_FLAG_FILE}"
                return
            fi

            echo "No existing server binaries found and SteamCMD failed; aborting start."
            echo "Check ${RUN_HOME}/.local/share/Steam/logs/stderr.txt for SteamCMD details."
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

adjust_permissions
resolve_password
validate_workshop_config
fetch_workshop_mods
open_console
open_output
main_loop
