#!/bin/bash
#
# tests/run-fixtures.sh: exercise the 2.4.0 migration surface (environment aliases, legacy mount
# shim, world auto-detect, console helper, and the 2.1.0-2.3.0 guarantees on a shimmed layout)
# against an image, and leave a shim fixture running for a real client join. Everything happens
# under RIG (default ~/necesse-24-rig), never inside the repository.
#
#   IMAGE=necesse-server:dev tests/run-fixtures.sh            all automated checks
#   IMAGE=... tests/run-fixtures.sh keep brammys               start the brammys-style fixture, leave it up
#   IMAGE=... tests/run-fixtures.sh keep karyeet               same for karyeet-style
#   IMAGE=... tests/run-fixtures.sh keep filecfg               same for karyeet-style with file-mounted cfg
#   tests/run-fixtures.sh clean                                stop and remove what this script created
#
# Environment: IMAGE (image under test), BASELINE_IMAGE (default ghcr.io/stargumbo/necesse-server:2.3.0;
# produces the world saves and is the log-diff reference), RIG (scratch directory), HOST_NET=1 (WSL2:
# bind the host's 14159 directly, bridge-published UDP does not reach a Windows client), PASSWORD
# (join password used throughout), MODS_COLLECTION (set on the karyeet-style fixture when given),
# PORT (with HOST_NET=1: SERVER_PORT for a kept fixture, so two can listen side by side).
set -euo pipefail

IMAGE="${IMAGE:-necesse-server:dev}"
BASELINE_IMAGE="${BASELINE_IMAGE:-ghcr.io/stargumbo/necesse-server:2.3.0}"
RIG="${RIG:-${HOME}/necesse-24-rig}"
HOST_NET="${HOST_NET:-0}"
PASSWORD="${PASSWORD:-Fixture-Pass-9f3k}"
MODS_COLLECTION="${MODS_COLLECTION:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="${HERE}/fixtures"
DATADIR=/home/necesse/.config/Necesse
PASS=0
FAIL=0

say()  { printf '\n=== %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
# check <description> <command...>: PASS when the command succeeds.
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "${desc}"; else fail "${desc}"; fi; }
logs() { docker logs "$1" 2>&1; }
rm_c() { docker rm -f "$@" >/dev/null 2>&1 || true; }

# wait_for <container> <pattern> [seconds]: until the log holds the pattern or the container exits.
wait_for() {
    local c="$1" pat="$2" n="${3:-90}" i
    for ((i = 0; i < n; i++)); do
        if logs "$c" | grep -q -- "$pat"; then return 0; fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]; then return 1; fi
        sleep 1
    done
    return 1
}
# wait_exit <container> [seconds]: prints the exit code, or "running".
wait_exit() {
    local c="$1" n="${2:-60}" i
    for ((i = 0; i < n; i++)); do
        if [ "$(docker inspect -f '{{.State.Running}}' "$c")" != "true" ]; then
            docker inspect -f '{{.State.ExitCode}}' "$c"; return 0
        fi
        sleep 1
    done
    echo running
}
wait_healthy() {
    local c="$1" n="${2:-100}" i
    for ((i = 0; i < n; i++)); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$c")" = "healthy" ] && return 0
        sleep 1
    done
    return 1
}
# Timestamps, ANSI colours, ephemeral ports/addresses and world-generation randomness (region load
# order, spawn tile) removed, so two runs can be diffed.
normalize_log() {
    sed -E 's/\x1b\[[0-9;]*m//g; s/\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\] //; s|logs/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9hms]+\.txt|logs/<timestamp>.txt|; /Started lan socket at port/d; /Local address:/d; /^[0-9]{4}-[0-9]{2}-[0-9]{2} /d; /Starting to load level presets region/d; /Found spawn tile at/d'
}

# world_zip <name>: path of a saved world zip with that name, produced once by the baseline image.
world_zip() {
    local name="$1"
    local dir="${RIG}/worlds/${name}"
    if [ ! -f "${dir}/saves/worlds/${name}.zip" ]; then
        mkdir -p "${dir}"
        rm_c n24-worldgen
        docker run -d --name n24-worldgen --stop-timeout 60 -e WORLD_NAME="${name}" \
            -v "${dir}:${DATADIR}" "${BASELINE_IMAGE}" >/dev/null
        if ! wait_for n24-worldgen "Started server"; then logs n24-worldgen; echo "world generation failed" >&2; exit 1; fi
        docker stop n24-worldgen >/dev/null
        rm_c n24-worldgen
    fi
    printf '%s' "${dir}/saves/worlds/${name}.zip"
}
# A server.cfg / banned.cfg pair as the game writes them (from the same baseline run).
seed_cfg_from() { cp "${RIG}/worlds/$1/cfg/server.cfg" "${RIG}/worlds/$1/cfg/banned.cfg" "$2/"; }

# compose_up <project> <dir> <service>: `docker compose up -d` in dir, with the host-network override on WSL2.
compose_up() {
    local proj="$1" dir="$2" svc="$3"
    local -a extra=()
    if [ "${HOST_NET}" = "1" ]; then
        {
            printf 'services:\n  %s:\n    network_mode: host\n    ports: !reset []\n' "${svc}"
            # PORT (host networking only): let two kept fixtures listen side by side.
            if [ -n "${PORT:-}" ]; then printf '    environment:\n      - SERVER_PORT=%s\n' "${PORT}"; fi
        } > "${dir}/host-network.override.yml"
        extra=(-f "${dir}/host-network.override.yml")
    fi
    (cd "${dir}" && IMAGE="${IMAGE}" PASSWORD="${PASSWORD}" PUID="${PUID:-1000}" PGID="${PGID:-1000}" \
        MODS_COLLECTION="${MODS_COLLECTION}" WORLD="${WORLD:-}" WORLD_NAME="${WORLD_NAME:-}" \
        docker compose -p "${proj}" -f compose.yml "${extra[@]}" up -d >/dev/null 2>&1)
}
# reclaim <dir>: re-own a directory the karyeet fixtures left root-owned, so it can be removed.
reclaim() { [ -d "$1" ] && docker run --rm -v "$1:/x" busybox chown -R "$(id -u):$(id -g)" /x >/dev/null 2>&1; return 0; }
compose_stop() { (cd "$2" && docker compose -p "$1" -f compose.yml stop >/dev/null 2>&1) || true; }
compose_down() { (cd "$2" 2>/dev/null && docker compose -p "$1" -f compose.yml down >/dev/null 2>&1) || true; }

password_hidden() { # password_hidden <container> <log text>
    local c="$1" L="$2" pid uid envs
    check "  password absent from docker logs" [ "$(grep -cF "${PASSWORD}" <<<"${L}")" -eq 0 ]
    check "  password absent from docker top" [ "$(docker top "${c}" | grep -cF "${PASSWORD}")" -eq 0 ]
    pid="$(docker exec "${c}" pgrep -f Server.jar 2>/dev/null | head -n 1 || true)"
    if [ -z "${pid}" ]; then fail "  java process not found; environment check skipped"; return; fi
    # /proc/<pid>/environ is readable only by the process owner (no CAP_SYS_PTRACE in the container).
    uid="$(docker exec "${c}" stat -c %u "/proc/${pid}")"
    envs="$(docker exec -u "${uid}" "${c}" sh -c "tr '\\0' '\\n' < /proc/${pid}/environ")"
    check "  PASSWORD/password/SERVER_PASSWORD absent from the java environment ($(wc -l <<<"${envs}") variables read)" \
        [ "$(grep -cE '^(PASSWORD|password|SERVER_PASSWORD)=' <<<"${envs}")" -eq 0 ]
}

# ------------------------------------------------------------------------------------------------
case_aliases() {
    local L
    say "Aliases: brammys-style env only"
    rm_c n24-alias-b
    docker run -d --name n24-alias-b -e WORLD=AliasWorld -e PASSWORD="${PASSWORD}" -e OWNER=AliasOwner \
        -e SLOTS=7 -e "MOTD=alias motd" -e PAUSE=1 -e GIVE_CLIENTS_POWER=1 -e JVMARGS=-Xmx1G "${IMAGE}" >/dev/null
    wait_for n24-alias-b "Started server" || true
    L="$(logs n24-alias-b)"
    grep -E '^WARN|^  /app' <<<"${L}" | sed 's|^  /app/jre/bin/java|  <java>|'
    check "exactly 7 alias WARN lines (GIVE_CLIENTS_POWER is already canonical)" \
        [ "$(grep -c '^WARN: .* is accepted as an alias of ' <<<"${L}")" -eq 7 ]
    local pair
    for pair in WORLD:WORLD_NAME PASSWORD:SERVER_PASSWORD OWNER:SERVER_OWNER SLOTS:SERVER_SLOTS MOTD:SERVER_MOTD PAUSE:PAUSE_WHEN_EMPTY JVMARGS:JAVA_OPTS; do
        check "  WARN for ${pair%%:*} names ${pair#*:}" grep -q "^WARN: ${pair%%:*} is accepted as an alias of ${pair#*:} " <<<"${L}"
    done
    check "  argv carries the alias values" grep -qE -- '-world +AliasWorld .*-slots +7 .*-owner +AliasOwner .*-motd +alias motd .*-pausewhenempty +1 .*-giveclientspower +1' <<<"${L}"
    check "  JVMARGS reached the JVM command line" grep -qE -- '^  /app/jre/bin/java +-Xmx1G +-jar' <<<"${L}"
    check "  server started" grep -q "Started server using port 14159 with 7 slots" <<<"${L}"
    check "  cfg holds the aliased password" docker exec n24-alias-b grep -q "password = ${PASSWORD}," "${DATADIR}/cfg/server.cfg"
    password_hidden n24-alias-b "${L}"
    rm_c n24-alias-b

    say "Aliases: karyeet-style lower-case keys"
    rm_c n24-alias-k
    docker run -d --name n24-alias-k -e world=AliasWorld -e password="${PASSWORD}" -e owner=AliasOwner \
        -e slots=7 -e "MOTD=alias motd" -e pauseWhenEmpty=true -e giveClientsPower=true -e JVM_OPTS=-Xmx1G "${IMAGE}" >/dev/null
    wait_for n24-alias-k "Started server" || true
    L="$(logs n24-alias-k)"
    grep -E '^WARN|^  /app' <<<"${L}" | sed 's|^  /app/jre/bin/java|  <java>|'
    check "exactly 8 alias WARN lines" [ "$(grep -c '^WARN: .* is accepted as an alias of ' <<<"${L}")" -eq 8 ]
    for pair in world:WORLD_NAME password:SERVER_PASSWORD owner:SERVER_OWNER slots:SERVER_SLOTS MOTD:SERVER_MOTD pauseWhenEmpty:PAUSE_WHEN_EMPTY giveClientsPower:GIVE_CLIENTS_POWER JVM_OPTS:JAVA_OPTS; do
        check "  WARN for ${pair%%:*} names ${pair#*:}" grep -q "^WARN: ${pair%%:*} is accepted as an alias of ${pair#*:} " <<<"${L}"
    done
    check "  argv carries the alias values" grep -qE -- '-world +AliasWorld .*-slots +7 .*-owner +AliasOwner .*-motd +alias motd .*-pausewhenempty +true .*-giveclientspower +true' <<<"${L}"
    check "  JVM_OPTS reached the JVM command line" grep -qE -- '^  /app/jre/bin/java +-Xmx1G +-jar' <<<"${L}"
    check "  server started" grep -q "Started server using port 14159 with 7 slots" <<<"${L}"
    check "  cfg holds the aliased password" docker exec n24-alias-k grep -q "password = ${PASSWORD}," "${DATADIR}/cfg/server.cfg"
    password_hidden n24-alias-k "${L}"
    rm_c n24-alias-k

    say "Aliases: canonical wins when both are set"
    rm_c n24-alias-c
    docker run -d --name n24-alias-c -e WORLD=AliasWorld -e WORLD_NAME=CanonWorld -e slots=7 -e SERVER_SLOTS=9 "${IMAGE}" >/dev/null
    wait_for n24-alias-c "Started server" || true
    L="$(logs n24-alias-c)"
    grep -E '^WARN' <<<"${L}"
    check "WARN says WORLD_NAME wins over WORLD" grep -q "^WARN: WORLD and WORLD_NAME are both set; WORLD_NAME wins and WORLD is ignored." <<<"${L}"
    check "WARN says SERVER_SLOTS wins over slots" grep -q "^WARN: slots and SERVER_SLOTS are both set; SERVER_SLOTS wins and slots is ignored." <<<"${L}"
    check "exactly 2 WARN lines" [ "$(grep -c '^WARN:' <<<"${L}")" -eq 2 ]
    check "argv uses the canonical values" grep -qE -- '-world +CanonWorld .*-slots +9 ' <<<"${L}"
    rm_c n24-alias-c
}

# ------------------------------------------------------------------------------------------------
setup_brammys() {
    local d="${RIG}/brammys"
    rm -rf "${d}"; mkdir -p "${d}/necesse/saves/worlds" "${d}/necesse/logs" "${d}/necesse/cfg"
    cp "$(world_zip Legacy)" "${d}/necesse/saves/worlds/Legacy.zip"
    seed_cfg_from Legacy "${d}/necesse/cfg"
    cp "${FIXTURES}/brammys-style.yml" "${d}/compose.yml"
    printf '%s' "${d}"
}
case_shim_brammys() {
    local d L
    say "Legacy mount shim: brammys-style (./necesse/{saves,logs,cfg} -> /necesse/...)"
    d="$(setup_brammys)"
    compose_up n24-brammys "${d}" necesse-server
    wait_for necesse-server "Started server" || true
    L="$(logs necesse-server)"
    grep -E '^Using |^Loading existing world|^WARN|Loading existing world at' <<<"${L}"
    check "three shim lines, one per mounted path" [ "$(grep -c '(legacy layout)\.$' <<<"${L}")" -eq 3 ]
    local n
    for n in saves logs cfg; do
        check "  Using /necesse/${n} for ${n} (legacy layout)" grep -q "^Using /necesse/${n} for ${n} (legacy layout)\.$" <<<"${L}"
    done
    check "  no mods line (not mounted)" bash -c "! grep -q 'for mods (legacy layout)' <<<'${L//\'/}'"
    check "  world auto-detected from the legacy saves" grep -q "^Loading existing world Legacy (auto-detected from saves/worlds/)\.$" <<<"${L}"
    check "  the game loaded that world" grep -q "Loading existing world at ${DATADIR}/saves/worlds/Legacy.zip" <<<"${L}"
    check "  data dir holds symlinks, not copies" docker exec necesse-server sh -c "[ -L ${DATADIR}/saves ] && [ -L ${DATADIR}/logs ] && [ -L ${DATADIR}/cfg ] && [ \"\$(readlink ${DATADIR}/saves)\" = /necesse/saves ] && [ ! -e ${DATADIR}/mods ]"
    check "  server.cfg behind the link is 0600" [ "$(stat -c %a "${d}/necesse/cfg/server.cfg")" = 600 ]
    check "  server.cfg behind the link holds the aliased password" grep -q "password = ${PASSWORD}," "${d}/necesse/cfg/server.cfg"
    check "  slots 25 from the SLOTS alias" grep -q "Started server using port 14159 with 25 slots" <<<"${L}"
    check "  new server log written behind the logs link" bash -c "ls '${d}/necesse/logs/'*.txt >/dev/null 2>&1"
    password_hidden necesse-server "${L}"
    say "Console helper (on the brammys-style container)"
    local out
    out="$(docker exec necesse-server console players 2>&1)" || true
    printf '%s\n' "${out}"
    check "console players prints 'Players online: 0/25'" grep -q "Players online: 0/25" <<<"${out}"
    out="$(docker exec necesse-server console 2>&1)" && rc=0 || rc=$?
    check "console with no arguments prints usage and exits 2" bash -c "[ ${rc} -eq 2 ] && grep -q '^Usage: console' <<<'${out//\'/}'"
    docker exec necesse-server sh -c 'echo players > /tmp/necesse-console'; sleep 2
    check "the FIFO path still works for echo" [ "$(logs necesse-server | grep -c 'Players online: 0/25')" -ge 2 ]
    check "healthcheck reports healthy" wait_healthy necesse-server
    if [ "${KEEP:-0}" = "1" ]; then return; fi
    compose_stop n24-brammys "${d}"
    check "console-stop save line on docker compose stop" grep -q "Completed world save before stopping server" <<<"$(logs necesse-server)"
    check "world zip still in the legacy tree (never moved or copied)" [ -f "${d}/necesse/saves/worlds/Legacy.zip" ]
    compose_down n24-brammys "${d}"
}

setup_karyeet() {
    local d="${RIG}/karyeet"
    reclaim "${d}"; rm -rf "${d}"; mkdir -p "${d}/saves/worlds" "${d}/logs" "${d}/cfg" "${d}/mods"
    cp "$(world_zip Legacy)" "${d}/saves/worlds/Legacy.zip"
    seed_cfg_from Legacy "${d}/cfg"
    cp "${FIXTURES}/karyeet-style.yml" "${d}/compose.yml"
    # karyeet-style files are root-owned on the host.
    docker run --rm -v "${d}:/x" busybox chown -R 0:0 /x/saves /x/logs /x/cfg /x/mods >/dev/null
    printf '%s' "${d}"
}
case_shim_karyeet() {
    local d L
    say "Legacy mount shim: karyeet-style (./{saves,logs,cfg,mods} -> /root/.config/Necesse/..., root-owned, PUID/PGID 1000)"
    d="$(setup_karyeet)"
    check "fixture files are root-owned before the start" [ "$(stat -c %u:%g "${d}/saves/worlds/Legacy.zip")" = "0:0" ]
    WORLD=Legacy compose_up n24-karyeet "${d}" necesse_server
    wait_for necesse_server "Started server" || true
    L="$(logs necesse_server)"
    grep -E '^Using |^Loading existing world|^WARN|Loading existing world at|Workshop|Found mod' <<<"${L}"
    check "four shim lines" [ "$(grep -c '(legacy layout)\.$' <<<"${L}")" -eq 4 ]
    local n
    for n in saves logs cfg mods; do
        check "  Using /root/.config/Necesse/${n} for ${n}" grep -q "^Using /root/.config/Necesse/${n} for ${n} (legacy layout)\.$" <<<"${L}"
    done
    check "  the game loaded the existing world" grep -q "Loading existing world at ${DATADIR}/saves/worlds/Legacy.zip" <<<"${L}"
    check "  5 alias WARN lines (world, slots, password, pauseWhenEmpty, giveClientsPower)" [ "$(grep -c '^WARN: .* is accepted as an alias of ' <<<"${L}")" -eq 5 ]
    check "  argv: -pausewhenempty true -giveclientspower true from the lower-case keys" grep -qE -- '-world +Legacy .*-slots +10 .*-pausewhenempty +true .*-giveclientspower +true' <<<"${L}"
    check "  files re-owned to PUID:PGID 1000:1000 (world zip)" [ "$(stat -c %u:%g "${d}/saves/worlds/Legacy.zip")" = "1000:1000" ]
    check "  files re-owned to PUID:PGID 1000:1000 (server.cfg)" [ "$(stat -c %u:%g "${d}/cfg/server.cfg")" = "1000:1000" ]
    check "  server.cfg 0600 with the aliased password" bash -c "[ \"\$(stat -c %a '${d}/cfg/server.cfg')\" = 600 ] && grep -q 'password = ${PASSWORD},' '${d}/cfg/server.cfg'"
    check "  java runs as uid 1000" [ "$(docker exec necesse_server sh -c 'stat -c %u /proc/$(pgrep -f Server.jar | head -n 1)')" = "1000" ]
    password_hidden necesse_server "${L}"
    local out
    out="$(docker exec necesse_server console players 2>&1)" || true
    check "  console players -> Players online: 0/10" grep -q "Players online: 0/10" <<<"${out}"
    if [ -n "${MODS_COLLECTION}" ]; then
        say "MODS_COLLECTION=${MODS_COLLECTION} on the shimmed layout"
        check "  collection resolved" grep -q "^Workshop collection: ${MODS_COLLECTION} resolved to" <<<"${L}"
        check "  managed ws- jar landed in the legacy mods directory" bash -c "ls '${d}/mods/'ws-*.jar >/dev/null 2>&1"
        check "  managed jar owned 1000:1000 mode 600" bash -c "f=\$(ls '${d}/mods/'ws-*.jar | head -n 1); [ \"\$(stat -c %u:%g:%a \"\$f\")\" = 1000:1000:600 ]"
        check "  the game found the mod" grep -q "Found mod: .* from ModsFolderModProvider" <<<"${L}"
        check "  ws-manifest.txt written beside mods/ (this image's data dir)" docker exec necesse_server test -f "${DATADIR}/ws-manifest.txt"
    fi
    check "healthcheck reports healthy" wait_healthy necesse_server
    if [ "${KEEP:-0}" = "1" ]; then return; fi
    compose_stop n24-karyeet "${d}"
    check "console-stop save line on docker compose stop" grep -q "Completed world save before stopping server" <<<"$(logs necesse_server)"
    compose_down n24-karyeet "${d}"
}

setup_karyeet_filecfg() {
    local d="${RIG}/karyeet-filecfg"
    reclaim "${d}"; rm -rf "${d}"; mkdir -p "${d}/saves/worlds" "${d}/logs" "${d}/mods"
    cp "$(world_zip Legacy)" "${d}/saves/worlds/Legacy.zip"
    seed_cfg_from Legacy "${d}"
    cp "${FIXTURES}/karyeet-style-file-cfg.yml" "${d}/compose.yml"
    docker run --rm -v "${d}:/x" busybox chown -R 0:0 /x/saves /x/logs /x/mods /x/server.cfg /x/banned.cfg >/dev/null
    printf '%s' "${d}"
}
case_shim_file_cfg() {
    local d L
    say "karyeet-style with server.cfg/banned.cfg mounted as single files, password from env (sender addition 1)"
    d="$(setup_karyeet_filecfg)"
    # root-owned 0600 on the host: read the checksum through a container.
    local banned_before; banned_before="$(docker run --rm -v "${d}:/x" busybox md5sum /x/banned.cfg | cut -d' ' -f1)"
    WORLD=Legacy compose_up n24-kfile "${d}" necesse_server
    wait_for necesse_server_filecfg "Started server" || true
    L="$(logs necesse_server_filecfg)"
    grep -E '^Using |^WARN|Loading existing world at|Started server' <<<"${L}"
    check "four shim lines, cfg one noting the file mount" [ "$(grep -c '(legacy layout' <<<"${L}")" -eq 4 ]
    check "  Using .../cfg (legacy layout; server.cfg is a file mount, written in place)" grep -q "^Using /root/.config/Necesse/cfg for cfg (legacy layout; server.cfg is a file mount, written in place)\.$" <<<"${L}"
    check "  the game loaded the existing world" grep -q "Loading existing world at ${DATADIR}/saves/worlds/Legacy.zip" <<<"${L}"
    check "  server started" grep -q "Started server using port" <<<"${L}"
    check "  the mounted server.cfg now holds the env password" grep -q "password = ${PASSWORD}," "${d}/server.cfg"
    check "  the mounted server.cfg is 0600 owned 1000:1000" [ "$(stat -c %u:%g:%a "${d}/server.cfg")" = "1000:1000:600" ]
    check "  banned.cfg untouched" [ "$(docker run --rm -v "${d}:/x" busybox md5sum /x/banned.cfg | cut -d' ' -f1)" = "${banned_before}" ]
    check "  the game announced a password (redacted to ****)" grep -q 'with password "\*\*\*\*"' <<<"${L}"
    password_hidden necesse_server_filecfg "${L}"
    local out; out="$(docker exec necesse_server_filecfg console players 2>&1)" || true
    check "  console players -> Players online: 0/10" grep -q "Players online: 0/10" <<<"${out}"
    check "healthcheck reports healthy" wait_healthy necesse_server_filecfg
    if [ "${KEEP:-0}" = "1" ]; then return; fi
    compose_stop n24-kfile "${d}"
    check "console-stop save line on docker compose stop" grep -q "Completed world save before stopping server" <<<"$(logs necesse_server_filecfg)"
    compose_down n24-kfile "${d}"
}

case_file_cfg_readonly() {
    local d="${RIG}/karyeet-filecfg-ro" L rc
    say "server.cfg mounted read-only as a single file -> refuse, name both, never start with the wrong password"
    reclaim "${d}"; rm -rf "${d}"; mkdir -p "${d}/saves/worlds" "${d}/logs"
    cp "$(world_zip Legacy)" "${d}/saves/worlds/Legacy.zip"
    seed_cfg_from Legacy "${d}"
    local before; before="$(md5sum < "${d}/server.cfg")"
    rm_c n24-filecfg-ro
    docker run -d --name n24-filecfg-ro -e world=Legacy -e password="${PASSWORD}" \
        -v "${d}/saves:/root/.config/Necesse/saves" -v "${d}/logs:/root/.config/Necesse/logs" \
        -v "${d}/server.cfg:/root/.config/Necesse/cfg/server.cfg:ro" "${IMAGE}" >/dev/null
    rc="$(wait_exit n24-filecfg-ro 60)"; L="$(logs n24-filecfg-ro)"; tail -1 <<<"${L}"
    check "container exited non-zero (exit ${rc})" bash -c "[ '${rc}' != running ] && [ '${rc}' -ne 0 ]"
    check "message names the data-dir path and the mounted file" grep -q "^${DATADIR}/cfg/server.cfg is the single-file mount /root/.config/Necesse/cfg/server.cfg, and it cannot be written" <<<"${L}"
    check "no 'Started server' line" bash -c "! grep -q 'Started server' <<<'${L//\'/}'"
    check "the mounted file is unchanged" [ "$(md5sum < "${d}/server.cfg")" = "${before}" ]
    rm_c n24-filecfg-ro
}

case_legacy_password_guard() {
    local d="${RIG}/pwguard" L rc
    say "legacy server.cfg carries a password, no password variable set -> refuse instead of opening the server"
    reclaim "${d}"; rm -rf "${d}"; mkdir -p "${d}/dir/saves/worlds" "${d}/dir/cfg" "${d}/file/saves/worlds"
    cp "$(world_zip Legacy)" "${d}/dir/saves/worlds/"; cp "$(world_zip Legacy)" "${d}/file/saves/worlds/"
    seed_cfg_from Legacy "${d}/dir/cfg"; seed_cfg_from Legacy "${d}/file"
    sed -i 's/^\tpassword = ,/\tpassword = Old-Secret-1,/' "${d}/dir/cfg/server.cfg" "${d}/file/server.cfg"
    rm_c n24-pw-dir n24-pw-file n24-pw-ok
    docker run -d --name n24-pw-dir -e world=Legacy -v "${d}/dir/saves:/root/.config/Necesse/saves" -v "${d}/dir/cfg:/root/.config/Necesse/cfg" "${IMAGE}" >/dev/null
    docker run -d --name n24-pw-file -e world=Legacy -v "${d}/file/saves:/root/.config/Necesse/saves" -v "${d}/file/server.cfg:/root/.config/Necesse/cfg/server.cfg" "${IMAGE}" >/dev/null
    rc="$(wait_exit n24-pw-dir 60)"; L="$(logs n24-pw-dir)"; tail -1 <<<"${L}"
    check "directory-mounted cfg: exit ${rc}, message names the file and SERVER_PASSWORD" bash -c "[ '${rc}' != running ] && [ '${rc}' -ne 0 ] && grep -q '^/root/.config/Necesse/cfg/server.cfg carries a join password, but neither SERVER_PASSWORD' <<<'${L//\'/}'"
    check "  the old password is not printed" [ "$(grep -c 'Old-Secret-1' <<<"${L}")" -eq 0 ]
    check "  file still holds the old password (nothing written)" grep -q "password = Old-Secret-1," "${d}/dir/cfg/server.cfg"
    rc="$(wait_exit n24-pw-file 60)"; L="$(logs n24-pw-file)"
    check "file-mounted cfg: exit ${rc}, same refusal" bash -c "[ '${rc}' != running ] && [ '${rc}' -ne 0 ] && grep -q '^/root/.config/Necesse/cfg/server.cfg carries a join password, but neither SERVER_PASSWORD' <<<'${L//\'/}'"
    check "  file still holds the old password" grep -q "password = Old-Secret-1," "${d}/file/server.cfg"
    say "  same layout with a password variable set -> starts, file now holds the configured password"
    docker run -d --name n24-pw-ok -e world=Legacy -e password="${PASSWORD}" -v "${d}/dir/saves:/root/.config/Necesse/saves" -v "${d}/dir/cfg:/root/.config/Necesse/cfg" "${IMAGE}" >/dev/null
    wait_for n24-pw-ok "Started server" || true
    check "server started" grep -q "Started server using port" <<<"$(logs n24-pw-ok)"
    check "server.cfg holds the configured password" grep -q "password = ${PASSWORD}," "${d}/dir/cfg/server.cfg"
    rm_c n24-pw-dir n24-pw-file n24-pw-ok
}

case_shim_safety() {
    local d="${RIG}/safety" L rc
    say "Shim safety: legacy mount AND a populated data-dir saves/ -> refuse, name both, change nothing"
    rm -rf "${d}"; mkdir -p "${d}/data/saves/worlds" "${d}/legacy/saves/worlds"
    cp "$(world_zip Legacy)" "${d}/legacy/saves/worlds/Legacy.zip"
    cp "$(world_zip Other)" "${d}/data/saves/worlds/Other.zip"
    local sum_before; sum_before="$(cd "${d}" && find . -type f -exec md5sum {} + | sort | md5sum)"
    rm_c n24-safety
    docker run -d --name n24-safety -v "${d}/data:${DATADIR}" -v "${d}/legacy/saves:/necesse/saves" "${IMAGE}" >/dev/null
    rc="$(wait_exit n24-safety 60)"
    L="$(logs n24-safety)"
    printf '%s\n' "${L}" | tail -3
    check "container exited non-zero (exit ${rc})" bash -c "[ '${rc}' != running ] && [ '${rc}' -ne 0 ]"
    check "message names both locations" grep -q "Both /necesse/saves (mounted, legacy layout) and ${DATADIR}/saves (this image's data directory) hold files for saves" <<<"${L}"
    check "no symlink was created, data/saves is still a directory" bash -c "[ -d '${d}/data/saves' ] && [ ! -L '${d}/data/saves' ]"
    check "nothing on disk changed (checksums of both trees)" [ "$(cd "${d}" && find . -type f -exec md5sum {} + | sort | md5sum)" = "${sum_before}" ]
    rm_c n24-safety
}

case_shim_off_logdiff() {
    local d="${RIG}/logdiff" a b
    say "Shim off by default: andreasgl4ser-style compose on fresh data dirs, log diff ${BASELINE_IMAGE} vs ${IMAGE}"
    rm -rf "${d}"; mkdir -p "${d}/base/data" "${d}/new/data"
    cp "${FIXTURES}/andreasgl4ser-style.yml" "${d}/base/compose.yml"; cp "${FIXTURES}/andreasgl4ser-style.yml" "${d}/new/compose.yml"
    (cd "${d}/base" && IMAGE="${BASELINE_IMAGE}" WORLD_NAME=DiffWorld PASSWORD="${PASSWORD}" docker compose -p n24-base -f compose.yml up -d >/dev/null 2>&1)
    wait_for necesse "Started server" || true
    a="$(logs necesse | normalize_log)"
    (cd "${d}/base" && docker compose -p n24-base -f compose.yml down >/dev/null 2>&1)
    (cd "${d}/new" && IMAGE="${IMAGE}" WORLD_NAME=DiffWorld PASSWORD="${PASSWORD}" docker compose -p n24-new -f compose.yml up -d >/dev/null 2>&1)
    wait_for necesse "Started server" || true
    b="$(logs necesse | normalize_log)"
    (cd "${d}/new" && docker compose -p n24-new -f compose.yml down >/dev/null 2>&1)
    if diff <(printf '%s\n' "${a}") <(printf '%s\n' "${b}") > "${d}/log.diff"; then
        pass "logs identical after normalisation ($(wc -l <<<"${a}") lines each)"
    else
        fail "logs differ:"; cat "${d}/log.diff"
    fi
    check "no shim line" bash -c "! grep -q 'legacy layout' <<<'${b//\'/}'"
    check "no WARN line" bash -c "! grep -q '^WARN' <<<'${b//\'/}'"
    check "data dir has real directories, no symlinks" bash -c "[ -d '${d}/new/data/saves' ] && [ ! -L '${d}/new/data/saves' ] && [ ! -L '${d}/new/data/cfg' ]"

    say "World auto-detect, zero worlds: WORLD_NAME unset -> new world named 'world', as before"
    rm -rf "${d}/zero-base" "${d}/zero-new"; mkdir -p "${d}/zero-base" "${d}/zero-new"
    rm_c n24-zero-base n24-zero-new
    docker run -d --name n24-zero-base -e WORLD_NAME= -v "${d}/zero-base:${DATADIR}" "${BASELINE_IMAGE}" >/dev/null
    docker run -d --name n24-zero-new -e WORLD_NAME= -v "${d}/zero-new:${DATADIR}" "${IMAGE}" >/dev/null
    wait_for n24-zero-base "Started server" || true; wait_for n24-zero-new "Started server" || true
    a="$(logs n24-zero-base | normalize_log)"; b="$(logs n24-zero-new | normalize_log)"
    check "new image creates world.zip" [ -f "${d}/zero-new/saves/worlds/world.zip" ]
    printf 'baseline (WORLD_NAME= blank): %s\nnew image: %s\n' "$(grep -o 'Creating new world at.*' <<<"${a}" || echo '(no -world flag: game default)')" "$(grep -o 'Creating new world at.*' <<<"${b}")"
    check "new image passes -world world" grep -qE -- '-world +world ' <<<"${b}"
    rm_c n24-zero-base n24-zero-new
}

case_autodetect() {
    local d="${RIG}/autodetect" L rc
    say "World auto-detect: exactly one world -> loaded and named"
    rm -rf "${d}"; mkdir -p "${d}/one/saves/worlds" "${d}/many/saves/worlds" "${d}/many-default/saves/worlds"
    cp "$(world_zip Solo)" "${d}/one/saves/worlds/"
    rm_c n24-ad-one
    docker run -d --name n24-ad-one -v "${d}/one:${DATADIR}" "${IMAGE}" >/dev/null
    wait_for n24-ad-one "Started server" || true
    L="$(logs n24-ad-one)"; grep -E '^Loading existing world|Loading existing world at' <<<"${L}"
    check "log names the detected world" grep -q "^Loading existing world Solo (auto-detected from saves/worlds/)\.$" <<<"${L}"
    check "the game loaded Solo.zip" grep -q "Loading existing world at ${DATADIR}/saves/worlds/Solo.zip" <<<"${L}"
    rm_c n24-ad-one

    say "World auto-detect: two worlds, neither named 'world' -> refuse and list"
    cp "$(world_zip Solo)" "${d}/many/saves/worlds/"; cp "$(world_zip Other)" "${d}/many/saves/worlds/"
    rm_c n24-ad-many
    docker run -d --name n24-ad-many -v "${d}/many:${DATADIR}" "${IMAGE}" >/dev/null
    rc="$(wait_exit n24-ad-many 60)"; L="$(logs n24-ad-many)"; tail -1 <<<"${L}"
    check "container exited non-zero (exit ${rc})" bash -c "[ '${rc}' != running ] && [ '${rc}' -ne 0 ]"
    check "message lists both worlds" grep -q "holds more than one world: Other, Solo\. Set WORLD_NAME" <<<"${L}"
    rm_c n24-ad-many

    say "World auto-detect: several worlds, one of them 'world' -> loads 'world' with a WARN (2.3.0 default kept)"
    cp "$(world_zip Solo)" "${d}/many-default/saves/worlds/"; cp "$(world_zip world)" "${d}/many-default/saves/worlds/"
    rm_c n24-ad-def
    docker run -d --name n24-ad-def -v "${d}/many-default:${DATADIR}" "${IMAGE}" >/dev/null
    wait_for n24-ad-def "Started server" || true
    L="$(logs n24-ad-def)"; grep -E '^WARN' <<<"${L}"
    check "WARN explains the choice" grep -q "^WARN: WORLD_NAME is not set and saves/worlds/ holds several worlds (Solo, world); loading 'world'" <<<"${L}"
    check "the game loaded world.zip" grep -q "Loading existing world at ${DATADIR}/saves/worlds/world.zip" <<<"${L}"
    rm_c n24-ad-def
}

# ------------------------------------------------------------------------------------------------
do_clean() {
    say "Cleaning up"
    compose_down n24-brammys "${RIG}/brammys"; compose_down n24-karyeet "${RIG}/karyeet"; compose_down n24-kfile "${RIG}/karyeet-filecfg"
    compose_down n24-base "${RIG}/logdiff/base"; compose_down n24-new "${RIG}/logdiff/new"
    rm_c n24-alias-b n24-alias-k n24-alias-c n24-filecfg n24-filecfg-ro n24-pw-dir n24-pw-file n24-pw-ok n24-safety n24-zero-base n24-zero-new n24-ad-one n24-ad-many n24-ad-def n24-worldgen
    reclaim "${RIG}/karyeet"; reclaim "${RIG}/karyeet-filecfg"; reclaim "${RIG}/karyeet-filecfg-ro"; reclaim "${RIG}/pwguard"
    rm -rf "${RIG}/brammys" "${RIG}/karyeet" "${RIG}/karyeet-filecfg" "${RIG}/karyeet-filecfg-ro" "${RIG}/pwguard" "${RIG}/safety" "${RIG}/logdiff" "${RIG}/autodetect"
    echo "kept: ${RIG}/worlds (generated world saves)"
}

do_keep() {
    export KEEP=1
    case "${1:-}" in
        brammys)
            case_shim_brammys
            echo; echo "brammys-style fixture is UP: container necesse-server, world Legacy, password ${PASSWORD}, 25 slots."
            ;;
        karyeet)
            case_shim_karyeet
            echo; echo "karyeet-style fixture is UP: container necesse_server, world Legacy, password ${PASSWORD}, 10 slots${MODS_COLLECTION:+, MODS_COLLECTION=${MODS_COLLECTION}}."
            ;;
        filecfg)
            case_shim_file_cfg
            echo; echo "karyeet-style file-mounted-cfg fixture is UP: container necesse_server_filecfg, world Legacy, password ${PASSWORD}, 10 slots."
            ;;
        *) echo "keep needs brammys, karyeet or filecfg" >&2; exit 2 ;;
    esac
    if [ "${HOST_NET}" = "1" ]; then echo "Join at 127.0.0.1:${PORT:-14159} (host networking)."; else echo "Join at <this host>:14159/udp."; fi
    printf '\nPASS %d  FAIL %d\n' "${PASS}" "${FAIL}"
}

case "${1:-all}" in
    clean) do_clean ;;
    keep)  do_keep "${2:-}" ;;
    all)
        echo "image under test: ${IMAGE}; baseline: ${BASELINE_IMAGE}; rig: ${RIG}; host networking: ${HOST_NET}"
        docker image inspect "${IMAGE}" >/dev/null
        case_aliases
        case_shim_brammys
        case_shim_karyeet
        case_shim_file_cfg
        case_file_cfg_readonly
        case_legacy_password_guard
        case_shim_safety
        case_shim_off_logdiff
        case_autodetect
        printf '\nPASS %d  FAIL %d\n' "${PASS}" "${FAIL}"
        [ "${FAIL}" -eq 0 ]
        ;;
    case_*)
        # Named cases only, e.g. `tests/run-fixtures.sh case_autodetect case_shim_safety`.
        for c in "$@"; do "${c}"; done
        printf '\nPASS %d  FAIL %d\n' "${PASS}" "${FAIL}"
        [ "${FAIL}" -eq 0 ]
        ;;
    *) echo "usage: $0 [all|case_<name>...|keep brammys|keep karyeet|clean]" >&2; exit 2 ;;
esac
