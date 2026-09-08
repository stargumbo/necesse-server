#!/bin/bash
#
# Fixed-string redaction of the join password in the server's stdout/stderr.
# Fed by the entrypoint through a FIFO; one line in, one line out, flushed per line so
# `docker logs -f` stays live. The secret arrives in NECESSE_REDACT_SECRET (never argv).
# The replacement is a quoted parameter-expansion pattern, so every character of the
# secret is literal: no regex, no globbing, metacharacters are fine.

secret="${NECESSE_REDACT_SECRET:-}"
unset NECESSE_REDACT_SECRET

while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${secret}" ]]; then
        line="${line//"${secret}"/****}"
    fi
    printf '%s\n' "${line}"
done
