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
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-50}"

SERVER_PID=""
AUTO_UPDATE_MONITOR_PID=""
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
    ) &
    AUTO_UPDATE_MONITOR_PID=$!
}

open_console() {
    rm -f "${CONSOLE_FIFO}"
    mkfifo -m 600 "${CONSOLE_FIFO}"
    # Read-write so the open never blocks and the server never sees EOF on stdin.
    exec 3<>"${CONSOLE_FIFO}"
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

    if [ -n "${SERVER_PASSWORD:-}" ]; then
        set -- "$@" -password "${SERVER_PASSWORD}"
    fi

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

    run_as_user "$@" <&3 &
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

        exit "${SERVER_EXIT_CODE}"
    done
}

trap 'handle_exit' INT TERM

adjust_permissions
open_console
main_loop
