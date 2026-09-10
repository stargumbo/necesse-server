#!/bin/bash
#
# Fixed-string redaction of the join password in the server's stdout/stderr.
# Fed by the entrypoint through a FIFO; one line in, one line out, flushed per line so
# `docker logs -f` stays live. The secret arrives in NECESSE_REDACT_SECRET (never argv).
# The replacement is a quoted parameter-expansion pattern, so every character of the
# secret is literal: no regex, no globbing, metacharacters are fine.
#
# Every (redacted) line is also appended to OUTPUT_LOG, the file the `console` helper reads to
# show a command's reply. It is rotated at about 1 MiB with one previous copy kept, so a
# long-running server never fills /tmp; both files are 0600.

secret="${NECESSE_REDACT_SECRET:-}"
unset NECESSE_REDACT_SECRET

OUTPUT_LOG="/tmp/necesse-output.log"
umask 077
exec 5>>"${OUTPUT_LOG}"
lines=0

while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${secret}" ]]; then
        line="${line//"${secret}"/****}"
    fi
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >&5
    lines=$((lines + 1))
    if (( lines % 200 == 0 )) && (( $(stat -c %s "${OUTPUT_LOG}" 2>/dev/null || echo 0) > 1048576 )); then
        mv -f "${OUTPUT_LOG}" "${OUTPUT_LOG}.1"
        exec 5>>"${OUTPUT_LOG}"
    fi
done
