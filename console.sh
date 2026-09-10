#!/bin/sh
#
# console: type a command into the running Necesse server's console and print its reply.
#
#   docker exec necesse console players        -> Players online: 0/10
#   docker exec necesse console help
#   docker exec necesse console say Restart in 5 minutes
#
# The arguments are written as one line to the console FIFO the entrypoint holds open for the
# server's stdin (the same /tmp/necesse-console that `echo players > /tmp/necesse-console` uses),
# then the redacted server output that follows is printed until the server has been quiet for
# CONSOLE_QUIET_SECONDS (default 2) or CONSOLE_TIMEOUT_SECONDS (default 10) have passed. The output
# is read from /tmp/necesse-output.log, the copy of the container log that redact.sh keeps, so the
# join password never appears here either. No daemon, no extra process besides this script.

set -eu

CONSOLE_FIFO="/tmp/necesse-console"
OUTPUT_LOG="/tmp/necesse-output.log"
quiet="${CONSOLE_QUIET_SECONDS:-2}"
timeout="${CONSOLE_TIMEOUT_SECONDS:-10}"

usage() {
    cat <<'USAGE'
Usage: console <server command> [arguments...]

Types the command into the Necesse server console and prints the server's reply.
Examples:
  console players             Players online: N/<slots>
  console help                the server's own command list (several pages: help 2, help 3, ...)
  console say <message>       broadcast a chat message
  console stop                save the world and stop the server (the container then exits)

Environment: CONSOLE_QUIET_SECONDS (default 2) ends the reply after that much silence;
             CONSOLE_TIMEOUT_SECONDS (default 10) is the overall cap.
USAGE
}

if [ $# -eq 0 ]; then
    usage
    exit 2
fi
case "$1" in
    -h|--help|help-console) usage; exit 0 ;;
esac

if [ ! -p "${CONSOLE_FIFO}" ]; then
    echo "console: ${CONSOLE_FIFO} does not exist; the server is not running in this container (yet)." >&2
    exit 1
fi
if [ ! -w "${CONSOLE_FIFO}" ]; then
    echo "console: ${CONSOLE_FIFO} is not writable by $(id -un); run it as the container's default user (docker exec without -u)." >&2
    exit 1
fi

# Lines already in the log are not part of the reply.
before=0
if [ -f "${OUTPUT_LOG}" ]; then
    before="$(wc -l < "${OUTPUT_LOG}")"
fi

printf '%s\n' "$*" > "${CONSOLE_FIFO}"

printed=0
seen="${before}"
elapsed=0
silent=0
while :; do
    sleep 0.5
    elapsed=$((elapsed + 1))
    now=0
    if [ -f "${OUTPUT_LOG}" ]; then
        now="$(wc -l < "${OUTPUT_LOG}")"
    fi
    if [ "${now}" -lt "${seen}" ]; then
        # redact.sh rotated the file between two polls: start from its top.
        seen=0
    fi
    if [ "${now}" -gt "${seen}" ]; then
        # ANSI colour codes stripped; everything else verbatim.
        tail -n +"$((seen + 1))" "${OUTPUT_LOG}" | head -n "$((now - seen))" | sed 's/\x1b\[[0-9;]*m//g'
        printed=$((printed + now - seen))
        seen="${now}"
        silent=0
    else
        silent=$((silent + 1))
    fi
    if [ "${printed}" -gt 0 ] && [ "${silent}" -ge $((quiet * 2)) ]; then
        break
    fi
    if [ "${elapsed}" -ge $((timeout * 2)) ]; then
        break
    fi
done

if [ "${printed}" -eq 0 ]; then
    echo "console: no reply within ${timeout}s (the command was sent; check docker logs)." >&2
    exit 1
fi
