#!/bin/bash
# shellcheck disable=SC2034,SC2329  # library: variables/functions are used by callers
# Helper functions shared by the test scripts and the CI workflow.
#   source scripts/lib.sh

VIP=172.28.0.100

# Node that currently runs the FloatingIP resource (asks any running cluster node)
active_node() {
    local n
    for n in webz-001 webz-002 webz-003; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = "true" ]; then
            docker exec "$n" crm_resource --resource FloatingIP --locate 2>/dev/null \
                | sed -n 's/.*is running on: \([^ ]*\).*/\1/p'
            return
        fi
    done
}

# Container that answered on the floating IP (X-Served-By header), seen from webz-004
served_by() {
    docker exec webz-004 curl -s -o /dev/null -D - --max-time 2 "http://${VIP}/" \
        | sed -n 's/^X-Served-By: \(.*\)\r$/\1/p' || true
}

# Wait (max $2 s, default 90) until a node other than $1 answers; prints it
wait_for_new_node() {
    local old="$1" max="${2:-90}" new=""
    for _ in $(seq 1 "$max"); do
        new="$(served_by)"
        if [ -n "$new" ] && [ "$new" != "$old" ]; then echo "$new"; return 0; fi
        sleep 1
    done
    return 1
}

# Any running cluster node, for pcs / crm commands
any_cluster_node() {
    local n
    for n in webz-001 webz-002 webz-003; do
        [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = "true" ] && { echo "$n"; return; }
    done
}

# Append a row to the GitHub Actions job summary (no-op locally)
summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$*" >> "$GITHUB_STEP_SUMMARY"
    return 0
}
