#!/bin/bash
#
# tests/run-platform.sh: the architecture-independent checks of the image, run the same way on amd64 and
# on arm64 (CI runs it on ubuntu-latest and on ubuntu-24.04-arm) against one already-built image: what is
# in the image, boot and world load, the console FIFO and helper, the password path, the healthcheck,
# UPDATE_ON_START and the auto-update restart through DepotDownloader, MODS_WORKSHOP and MODS_COLLECTION,
# and the console stop that saves the world. Everything happens under RIG, never inside the repository;
# containers are named npf-*. The 2.4.0 migration surface (aliases, legacy mounts, the log diff against an
# earlier image) is tests/run-fixtures.sh, which needs an amd64 baseline image and stays amd64-only.
#
#   IMAGE=necesse-server:dev tests/run-platform.sh            all checks
#   IMAGE=... tests/run-platform.sh case_boot_stop ...         named cases only
#   tests/run-platform.sh clean                                remove what this script created
#
# Environment: IMAGE (the image under test), RIG (scratch directory, default ~/necesse-platform-rig),
# PASSWORD (join password used throughout), WORKSHOP_ITEM (a Workshop item id; default 2827931647,
# Increased Stack Size), WORKSHOP_COLLECTION (a public collection id holding it; default 3798847765),
# BOOT_DEADLINE_SECONDS (default 180), STOP_DEADLINE_SECONDS (default 60), EXPECTED_SERVER_JAR_SHA256
# (when set, the image's Server.jar must hash to it). On GitHub Actions a summary table is appended to
# GITHUB_STEP_SUMMARY.
set -euo pipefail

IMAGE="${IMAGE:-}"
RIG="${RIG:-${HOME}/necesse-platform-rig}"
PASSWORD="${PASSWORD:-Platform-Pass-7q2x}"
WORKSHOP_ITEM="${WORKSHOP_ITEM:-2827931647}"
WORKSHOP_COLLECTION="${WORKSHOP_COLLECTION:-3798847765}"
BOOT_DEADLINE_SECONDS="${BOOT_DEADLINE_SECONDS:-180}"
STOP_DEADLINE_SECONDS="${STOP_DEADLINE_SECONDS:-60}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
EXPECTED_SERVER_JAR_SHA256="${EXPECTED_SERVER_JAR_SHA256:-}"
DATADIR=/home/necesse/.config/Necesse
MANIFESTS_FILE=/app/.necesse-manifests
JAVA=/opt/java/openjdk/bin/java
PASS=0
FAIL=0
declare -A TIMING=()
declare -a TIMING_ORDER=()
SERVER_JAR_SHA256=""
IMAGE_MANIFESTS=""
IMAGE_INFO=""

say()  { printf '\n=== %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
# check <description> <command...>: PASS when the command succeeds.
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "${desc}"; else fail "${desc}"; fi; }
present() { grep -q -- "$1" <<<"$2"; }
absent()  { ! grep -q -- "$1" <<<"$2"; }
count()   { grep -c -- "$1" <<<"$2" || true; }
logs() { docker logs "$1" 2>&1; }
rm_c() { docker rm -f "$@" >/dev/null 2>&1 || true; }
now() { date +%s; }
timing() { TIMING["$1"]="$2"; TIMING_ORDER+=("$1"); }

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
# wait_count <container> <pattern> <count> [seconds]: until the log holds the pattern at least count times.
wait_count() {
    local c="$1" pat="$2" want="$3" n="${4:-90}" i
    for ((i = 0; i < n; i++)); do
        if [ "$(logs "$c" | grep -c -- "$pat" || true)" -ge "$want" ]; then return 0; fi
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
# in_dir <host dir> <sh script>: run a shell snippet as root in a throwaway container with the directory at
# /x. Files the server wrote are 0600 owned by 1000:1000, which the user running this script may not be.
in_dir() { docker run --rm -v "$1:/x" --entrypoint sh "${IMAGE}" -c "$2"; }
reclaim() { [ -d "$1" ] && in_dir "$1" "chown -R $(id -u):$(id -g) /x" >/dev/null 2>&1; return 0; }

# run_bg <name> <data dir> [docker run args...]: start a container on a fresh data directory with the
# standard bind mount and join password.
run_bg() {
    local name="$1" dir="$2"; shift 2
    rm_c "${name}"; reclaim "${dir}"; rm -rf "${dir}"; mkdir -p "${dir}"
    docker run -d --name "${name}" --stop-timeout "$((STOP_DEADLINE_SECONDS + 10))" \
        -e SERVER_PASSWORD="${PASSWORD}" -v "${dir}:${DATADIR}" "$@" "${IMAGE}" >/dev/null
}
# boot <name> <label>: wait for 'Started server' and record how long it took.
boot() {
    local name="$1" label="$2" t0
    t0="$(now)"
    if wait_for "${name}" "Started server" "${BOOT_DEADLINE_SECONDS}"; then
        timing "${label}: container start to 'Started server'" "$(( $(now) - t0 )) s"
        pass "${label}: 'Started server' after $(( $(now) - t0 )) s"
    else
        fail "${label}: no 'Started server' within ${BOOT_DEADLINE_SECONDS} s (container $(docker inspect -f '{{.State.Status}}' "${name}"))"
        logs "${name}" | tail -n 40
    fi
}
# stop_and_check <name> <label>: docker stop (console stop inside), then the exit code, time and save line.
stop_and_check() {
    local name="$1" label="$2" t0 code elapsed L
    # A `stop` typed within about two seconds of a fresh world's 'Started server' can end in 'Stopped server'
    # with no 'Completed world save before stopping server' line, in the game's own log as well (seen once
    # on amd64, 2026-09-11; the world file was written all the same). Let the game settle first.
    sleep "${SETTLE_SECONDS}"
    t0="$(now)"
    docker stop "${name}" >/dev/null 2>&1 || true
    code="$(wait_exit "${name}" 5)"
    elapsed="$(( $(now) - t0 ))"
    timing "${label}: docker stop to exit" "${elapsed} s, exit code ${code}"
    L="$(logs "${name}")"
    grep -E '> stop|Starting world save|Completed world save|Stopped server|Error in server ticking' <<<"${L}" | tail -n 6 || true
    check "${label}: console stop exited 0 within ${STOP_DEADLINE_SECONDS} s (exit ${code} after ${elapsed} s)" \
        bash -c "[ '${code}' = 0 ] && [ '${elapsed}' -le '${STOP_DEADLINE_SECONDS}' ]"
    check "  'Completed world save before stopping server' logged" present 'Completed world save before stopping server' "${L}"
    check "  no 'Error in server ticking' after the stop" absent 'Error in server ticking' "${L}"
}
password_hidden() { # password_hidden <container> <log text>
    local c="$1" L="$2" pid uid envs
    check "  password absent from docker logs" [ "$(count "${PASSWORD}" "${L}")" -eq 0 ]
    check "  password absent from docker top" [ "$(docker top "${c}" | grep -cF "${PASSWORD}")" -eq 0 ]
    pid="$(docker exec "${c}" pgrep -f Server.jar 2>/dev/null | head -n 1 || true)"
    if [ -z "${pid}" ]; then fail "  java process not found; environment check skipped"; return; fi
    uid="$(docker exec "${c}" stat -c %u "/proc/${pid}")"
    envs="$(docker exec -u "${uid}" "${c}" sh -c "tr '\\0' '\\n' < /proc/${pid}/environ")"
    check "  PASSWORD/password/SERVER_PASSWORD absent from the java environment" \
        [ "$(grep -cE '^(PASSWORD|password|SERVER_PASSWORD)=' <<<"${envs}")" -eq 0 ]
    check "  java runs as uid 1000" [ "${uid}" = "1000" ]
}

# ------------------------------------------------------------------------------------------------
case_image() {
    say "Image: ${IMAGE} on $(uname -m)"
    local out
    IMAGE_INFO="$(docker image inspect "${IMAGE}" --format '{{.Os}}/{{.Architecture}}, {{.Size}} bytes')"
    echo "image ${IMAGE_INFO}"
    out="$(docker run --rm --entrypoint sh "${IMAGE}" -c '
        echo "arch=$(uname -m)"
        echo "java=$(command -v java) ($(java -version 2>&1 | head -n 1))"
        echo "jar=$(sha256sum /app/Server.jar | cut -d" " -f1)"
        echo "jre=$([ -e /app/jre ] && echo present || echo absent)"
        echo "linux64=$([ -e /app/linux64 ] && echo present || echo absent)"
        echo "steamcmd=$(command -v steamcmd || echo absent)"
        echo "gosu=$(command -v gosu || echo absent)"
        echo "dd=$(/opt/depotdownloader/DepotDownloader -V 2>&1 | head -n 1)"
        echo "manifests=$(tr "\n" "," < /app/.necesse-manifests)"
        echo "notice=$([ -f /usr/share/doc/necesse-server/NOTICE ] && [ -f /opt/depotdownloader/LICENSE ] && [ -f /opt/depotdownloader/RELEASE.txt ] && echo present || echo missing)"
        echo "app=$(du -sh /app | cut -f1)"
    ')"
    printf '%s\n' "${out}"
    SERVER_JAR_SHA256="$(sed -n 's/^jar=//p' <<<"${out}")"
    IMAGE_MANIFESTS="$(sed -n 's/^manifests=//p' <<<"${out}")"
    check "container arch is the host's ($(uname -m))" present "^arch=$(uname -m)$" "${out}"
    check "java is the base image's JRE (${JAVA})" present "^java=${JAVA} " "${out}"
    check "no jre/ from Steam in /app" present '^jre=absent$' "${out}"
    check "no linux64/ from Steam in /app" present '^linux64=absent$' "${out}"
    check "no steamcmd in the image" present '^steamcmd=absent$' "${out}"
    check "gosu present" present '^gosu=/usr/sbin/gosu$' "${out}"
    check "DepotDownloader runs on this platform" present '^dd=DepotDownloader v' "${out}"
    check "installed manifests recorded for depots 1006 and 1169375" present '^manifests=1006 [0-9][0-9]*,1169375 [0-9][0-9]*,$' "${out}"
    check "NOTICE, DepotDownloader LICENSE and RELEASE.txt in the image" present '^notice=present$' "${out}"
    if [ -n "${EXPECTED_SERVER_JAR_SHA256}" ]; then
        check "Server.jar sha256 is ${EXPECTED_SERVER_JAR_SHA256}" [ "${SERVER_JAR_SHA256}" = "${EXPECTED_SERVER_JAR_SHA256}" ]
    fi
}

case_boot_stop() {
    local d="${RIG}/boot" L out
    say "Boot on a fresh data directory (WORLD_NAME=Probe): console, password path, healthcheck, console stop"
    run_bg npf-boot "${d}" -e WORLD_NAME=Probe
    boot npf-boot "boot"
    L="$(logs npf-boot)"
    grep -E '^Join password|^  /opt|Natives path|Loading dedicated server|Started server' <<<"${L}" || true
    check "launch command uses ${JAVA}" present "^  ${JAVA}  *-jar  *Server.jar  *-nogui " "${L}"
    check "game version line present" present 'Loading dedicated server on version' "${L}"
    check "started with 10 slots on port 14159, world Probe" present 'Started server using port 14159 with 10 slots on world "Probe.zip"' "${L}"
    docker exec npf-boot grep 'Natives path' "${DATADIR}/latest-server-log.txt" || true
    check "natives loaded from Server.jar (Natives path: INTERNAL in the game log)" docker exec npf-boot grep -q 'Natives path: INTERNAL' "${DATADIR}/latest-server-log.txt"
    check "password announced as **** (redacted)" present 'with password "\*\*\*\*"' "${L}"
    check "no WARN lines with canonical variables" absent '^WARN' "${L}"
    check "cfg/server.cfg holds the password, mode 0600" docker exec npf-boot sh -c "grep -q 'password = ${PASSWORD},' ${DATADIR}/cfg/server.cfg && [ \"\$(stat -c %a ${DATADIR}/cfg/server.cfg)\" = 600 ]"
    password_hidden npf-boot "${L}"
    check "healthcheck reports healthy" wait_healthy npf-boot
    out="$(docker exec npf-boot console players 2>&1)" || true
    check "console helper: 'players' -> Players online: 0/10" present 'Players online: 0/10' "${out}"
    docker exec npf-boot sh -c 'echo players > /tmp/necesse-console'; sleep 2
    check "the console FIFO takes an echo too" [ "$(count 'Players online: 0/10' "$(logs npf-boot)")" -ge 2 ]
    stop_and_check npf-boot "boot"
    check "world saved as saves/worlds/Probe.zip, 0600 owned 1000:1000" \
        [ "$(in_dir "${d}" 'stat -c %u:%g:%a /x/saves/worlds/Probe.zip')" = "1000:1000:600" ]
    rm_c npf-boot

    say "World load: same data directory, WORLD_NAME unset -> auto-detected and loaded"
    rm_c npf-load
    docker run -d --name npf-load --stop-timeout "$((STOP_DEADLINE_SECONDS + 10))" -e SERVER_PASSWORD="${PASSWORD}" \
        -v "${d}:${DATADIR}" "${IMAGE}" >/dev/null
    boot npf-load "world load"
    L="$(logs npf-load)"
    check "auto-detect line names Probe" present '^Loading existing world Probe (auto-detected from saves/worlds/)\.$' "${L}"
    check "the game loaded Probe.zip" present "Loading existing world at ${DATADIR}/saves/worlds/Probe.zip" "${L}"
    stop_and_check npf-load "world load"
    rm_c npf-load
}

case_update_on_start() {
    local d="${RIG}/update" L out t0
    say "UPDATE_ON_START=true: DepotDownloader refreshes /app before the launch"
    run_bg npf-update "${d}" -e WORLD_NAME=Probe -e UPDATE_ON_START=true
    t0="$(now)"
    if wait_for npf-update "DepotDownloader run complete" "${BOOT_DEADLINE_SECONDS}"; then
        timing "update on start: DepotDownloader run" "$(( $(now) - t0 )) s"
    fi
    boot npf-update "update on start"
    L="$(logs npf-update)"
    grep -E '^Running DepotDownloader|anonymous account|^Processing depot|^Depot [0-9]+ -|^Total downloaded|^DepotDownloader run' <<<"${L}" || true
    check "announces the DepotDownloader run" present '^Running DepotDownloader to install or update Necesse (anonymous, app 1169370)' "${L}"
    check "anonymous dedicated-server login" present 'Using anonymous account with dedicated server subscription' "${L}"
    check "both depots processed (1006, 1169375)" bash -c "grep -q '^Processing depot 1006' <<<\"\$0\" && grep -q '^Processing depot 1169375' <<<\"\$0\"" "${L}"
    check "run complete" present '^DepotDownloader run complete' "${L}"
    out="$(docker exec npf-update sh -c 'echo "jar=$(sha256sum /app/Server.jar | cut -d" " -f1)"; echo "jre=$(find /app/jre /app/linux64 -type f 2>/dev/null | wc -l)"; echo "manifests=$(tr "\n" "," < /app/.necesse-manifests)"; echo "owner=$(stat -c %U /app/.necesse-manifests /app/.DepotDownloader | sort -u | tr "\n" ",")"')"
    printf '%s\n' "${out}"
    check "Server.jar unchanged by the update (sha256 ${SERVER_JAR_SHA256:0:12}...)" present "^jar=${SERVER_JAR_SHA256}$" "${out}"
    check "no file under jre/ or linux64/ after the update" present '^jre=0$' "${out}"
    check "installed manifests re-recorded, same as the image's" present "^manifests=${IMAGE_MANIFESTS}$" "${out}"
    check "manifest record and DepotDownloader state owned by necesse" present '^owner=necesse,$' "${out}"
    stop_and_check npf-update "update on start"
    rm_c npf-update
}

case_auto_update() {
    local d="${RIG}/auto" L t0
    say "AUTO_UPDATE_INTERVAL_MINUTES=1: a changed manifest stops the server (saving), refreshes and restarts it"
    run_bg npf-auto "${d}" -e WORLD_NAME=Probe -e AUTO_UPDATE_INTERVAL_MINUTES=1
    boot npf-auto "auto-update"
    check "monitor announced" present 'Auto-update: enabled; checking for new builds every 1 minute(s)' "$(logs npf-auto)"
    # Pretend the installed game depot is older than Steam's: the next check then sees a new build.
    docker exec -u 0 npf-auto sh -c "sed -i 's/^1169375 .*/1169375 1/' ${MANIFESTS_FILE}"
    t0="$(now)"
    if wait_for npf-auto "Auto-update: new build detected" 150; then
        timing "auto-update: tampered record to 'new build detected'" "$(( $(now) - t0 )) s"
        pass "new build detected after $(( $(now) - t0 )) s (local manifest 1 vs Steam's)"
    else
        fail "no 'Auto-update: new build detected' within 150 s"
    fi
    t0="$(now)"
    if wait_count npf-auto "Started server using port" 2 "${BOOT_DEADLINE_SECONDS}"; then
        timing "auto-update: 'new build detected' to second 'Started server'" "$(( $(now) - t0 )) s"
    fi
    L="$(logs npf-auto)"
    grep -E '^Auto-update|Completed world save|^Running DepotDownloader|^DepotDownloader run|Started server' <<<"${L}" || true
    check "detection names local and remote manifests" present '^Auto-update: new build detected (local .*1169375:1.*, remote .*1169375:[0-9]' "${L}"
    check "server saved before the update restart" present 'Completed world save before stopping server' "${L}"
    check "restart announced" present '^Auto-update: restarting server with fresh binaries' "${L}"
    check "DepotDownloader ran for the update" present '^Running DepotDownloader to install or update Necesse' "${L}"
    check "server started a second time" [ "$(count 'Started server using port' "${L}")" -ge 2 ]
    check "manifest record restored to Steam's ids" [ "$(docker exec npf-auto sh -c "tr '\n' ',' < ${MANIFESTS_FILE}")" = "${IMAGE_MANIFESTS}" ]
    check "no 'Error in server ticking'" absent 'Error in server ticking' "${L}"
    check "healthcheck reports healthy after the restart" wait_healthy npf-auto
    stop_and_check npf-auto "auto-update"
    rm_c npf-auto
}

case_workshop() {
    local d="${RIG}/ws" L manifest rc
    say "MODS_WORKSHOP=${WORKSHOP_ITEM}: fetched through DepotDownloader, installed as a managed jar"
    run_bg npf-ws "${d}" -e WORLD_NAME=Probe -e MODS_WORKSHOP="${WORKSHOP_ITEM}"
    boot npf-ws "workshop"
    L="$(logs npf-ws)"
    grep -E '^Workshop|Found mod' <<<"${L}" || true
    check "fetch announced" present "^Workshop mods: fetching item(s) ${WORKSHOP_ITEM} from app 1169040 with an anonymous login" "${L}"
    check "item installed as ws-${WORKSHOP_ITEM}-<name>.jar" present "^Workshop mods: item ${WORKSHOP_ITEM} installed as ws-${WORKSHOP_ITEM}-.*\.jar, [0-9]*s\.$" "${L}"
    check "the game found the mod" present 'Found mod: .* from ModsFolderModProvider' "${L}"
    manifest="$(docker exec npf-ws cat "${DATADIR}/ws-manifest.txt" 2>/dev/null || true)"
    printf 'ws-manifest.txt: %s\n' "${manifest}"
    check "ws-manifest.txt: id, jar, manifest=<id>, timeupdated=<epoch>, status=ok" \
        present "^${WORKSHOP_ITEM}"$'\t''[^'$'\t'']*\.jar'$'\t''manifest=[0-9][0-9]*'$'\t''timeupdated=[0-9][0-9]*'$'\t''status=ok$' "${manifest}"
    check "managed jar 0600 owned 1000:1000" \
        [ "$(in_dir "${d}" "stat -c %u:%g:%a /x/mods/ws-${WORKSHOP_ITEM}-*.jar")" = "1000:1000:600" ]
    check "no leftover from the fetch in the data directory (only mods/ and ws-manifest.txt)" \
        [ "$(in_dir "${d}" 'ls /x | grep -c -E "^(depots|content|steamapps)$"')" = "0" ]
    stop_and_check npf-ws "workshop"
    rm_c npf-ws

    say "MODS_WORKSHOP=1 (no such item), MODS_FAIL_FAST=true -> refuse to start, naming the item and the reason"
    run_bg npf-ws-bad "${RIG}/ws-bad" -e WORLD_NAME=Probe -e MODS_WORKSHOP=1
    rc="$(wait_exit npf-ws-bad 120)"
    L="$(logs npf-ws-bad)"
    grep -E '^Workshop' <<<"${L}" || true
    check "exited non-zero (exit ${rc})" bash -c "[ '${rc}' != running ] && [ '${rc}' -ne 0 ]"
    check "names the item and DepotDownloader's reason" present '^Workshop mods: item 1 failed to download (Unable to locate manifest ID for published file 1)\.$' "${L}"
    check "fail-fast refusal" present 'item(s) 1 could not be fetched; refusing to start with a partial mod set (MODS_FAIL_FAST=true)' "${L}"
    check "no 'Started server'" absent 'Started server' "${L}"
    rm_c npf-ws-bad
}

case_collection() {
    local d="${RIG}/coll" L
    say "MODS_COLLECTION=${WORKSHOP_COLLECTION}: resolved through the Steam Web API, items fetched through DepotDownloader"
    run_bg npf-coll "${d}" -e WORLD_NAME=Probe -e MODS_COLLECTION="${WORKSHOP_COLLECTION}"
    boot npf-coll "collection"
    L="$(logs npf-coll)"
    grep -E '^Workshop|Found mod' <<<"${L}" || true
    check "collection resolved" present "^Workshop collection: ${WORKSHOP_COLLECTION} resolved to [0-9]* item(s): " "${L}"
    check "items installed" present '^Workshop mods: item [0-9]* installed as ws-' "${L}"
    check "the game found the mod(s)" present 'Found mod: .* from ModsFolderModProvider' "${L}"
    check "ws-collection.txt written (last-known-good)" docker exec npf-coll test -s "${DATADIR}/ws-collection.txt"
    check "ws-manifest.txt written" docker exec npf-coll test -s "${DATADIR}/ws-manifest.txt"
    stop_and_check npf-coll "collection"
    rm_c npf-coll
}

# ------------------------------------------------------------------------------------------------
summary() {
    local k
    printf '\nPASS %d  FAIL %d\n' "${PASS}" "${FAIL}"
    printf '\n%-60s %s\n' "timing" "value"
    for k in "${TIMING_ORDER[@]}"; do printf '%-60s %s\n' "${k}" "${TIMING[${k}]}"; done
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "### run-platform.sh on $(uname -m): PASS ${PASS}, FAIL ${FAIL}"
            echo
            echo "| Item | Value |"
            echo "| --- | --- |"
            echo "| Image | ${IMAGE} (${IMAGE_INFO}) |"
            echo "| Server.jar sha256 | ${SERVER_JAR_SHA256:-n/a} |"
            echo "| Installed manifests | ${IMAGE_MANIFESTS:-n/a} |"
            for k in "${TIMING_ORDER[@]}"; do echo "| ${k} | ${TIMING[${k}]} |"; done
        } >> "${GITHUB_STEP_SUMMARY}"
    fi
}

do_clean() {
    say "Cleaning up"
    rm_c npf-boot npf-load npf-update npf-auto npf-ws npf-ws-bad npf-coll
    local d
    for d in boot update auto ws ws-bad coll; do
        [ -d "${RIG}/${d}" ] && [ -n "${IMAGE}" ] && reclaim "${RIG}/${d}"
        rm -rf "${RIG:?}/${d}"
    done
    rmdir "${RIG}" 2>/dev/null || true
}

case "${1:-all}" in
    clean) do_clean ;;
    all)
        [ -n "${IMAGE}" ] || { echo "IMAGE is required" >&2; exit 2; }
        echo "image under test: ${IMAGE}; rig: ${RIG}; host: $(uname -m) $(nproc) vCPU"
        docker image inspect "${IMAGE}" >/dev/null
        case_image
        case_boot_stop
        case_update_on_start
        case_auto_update
        case_workshop
        case_collection
        summary
        [ "${FAIL}" -eq 0 ]
        ;;
    case_*)
        [ -n "${IMAGE}" ] || { echo "IMAGE is required" >&2; exit 2; }
        docker image inspect "${IMAGE}" >/dev/null
        case_image
        for c in "$@"; do [ "${c}" = case_image ] || "${c}"; done
        summary
        [ "${FAIL}" -eq 0 ]
        ;;
    *) echo "usage: $0 [all|case_<name>...|clean]" >&2; exit 2 ;;
esac
