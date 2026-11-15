#!/bin/bash
# Jenkins job body: curl the floating IP and APPEND one line per run to the log.
# Line format:
#   <run time> | node=<container that answered> | http=<code> | curl_rc=<rc> | <page text>
set -u

VIP="${VIP:-172.28.0.100}"
PORT="${PORT:-80}"
LOG="${LOG:-/var/log/webz/curl.log}"

TS="$(date '+%Y-%m-%d %H:%M:%S %Z')"
HDR="$(mktemp)"

BODY="$(curl -sS --max-time 10 -D "$HDR" "http://${VIP}:${PORT}/" 2>&1)"
RC=$?

CODE="$(awk 'NR==1 {print $2}' "$HDR")"
NODE="$(grep -i '^X-Served-By:' "$HDR" | cut -d' ' -f2- | tr -d '\r')"
# one line, drop <head>...</head>, strip HTML tags -> "Junior DevOps Engineer - Home Task"
TEXT="$(printf '%s' "$BODY" | tr -s ' \t\r\n' ' ' \
        | sed -e 's#<head>.*</head>##' -e 's/<[^>]*>//g' -e 's/^ *//' -e 's/ *$//')"
rm -f "$HDR"

# >> appends: records from previous runs are never overwritten
echo "${TS} | node=${NODE:-unknown} | http=${CODE:-000} | curl_rc=${RC} | ${TEXT}" >> "$LOG"

echo "--- last records in ${LOG} ---"
tail -n 5 "$LOG"

# Mark the build as failed if the floating IP did not answer
exit "$RC"
