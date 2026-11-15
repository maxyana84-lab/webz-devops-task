#!/bin/bash
# Tests 1-5 from the task, automated.
#   ./scripts/failover-test.sh            # graceful: docker stop (pacemaker moves resources away)
#   ./scripts/failover-test.sh --kill     # hard failure: docker kill (corosync detects node loss)
#   ./scripts/failover-test.sh --cascade  # kill the active node twice: 001 -> 002 -> 003
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=stop; ROUNDS=1
case "${1:-}" in
    --kill)    MODE=kill ;;
    --cascade) MODE=kill; ROUNDS=2 ;;
esac

active_node() {
    for n in webz-001 webz-002 webz-003; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = "true" ]; then
            docker exec "$n" crm_resource --resource FloatingIP --locate 2>/dev/null \
                | sed -n 's/.*is running on: \([^ ]*\).*/\1/p'
            return
        fi
    done
}

served_by() {
    docker exec webz-004 curl -s -o /dev/null -D - --max-time 2 http://172.28.0.100/ \
        | sed -n 's/^X-Served-By: \(.*\)\r$/\1/p' || true
}

# Trigger the Jenkins job through its REST API (same job the 5-minute timer runs)
jenkins_build() {
    docker exec webz-004 bash -c '
        J=http://localhost:8080; JOB=webz-floating-ip-check
        AUTH="$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD"; JAR=$(mktemp)
        CRUMB=$(curl -s -c "$JAR" -u "$AUTH" "$J/crumbIssuer/api/json" \
                | sed -E "s/.*\"crumb\":\"([^\"]+)\".*\"crumbRequestField\":\"([^\"]+)\".*/\2:\1/")
        curl -s -b "$JAR" -u "$AUTH" -H "$CRUMB" -X POST "$J/job/$JOB/build" -o /dev/null \
             -w "Jenkins build queued: HTTP %{http_code}\n"
        sleep 12
        echo "--- console of the last build ---"
        curl -s -u "$AUTH" "$J/job/$JOB/lastBuild/consoleText" | grep -vE "^\[|^Running|^Building"'
}

echo "== Before the failure: Jenkins run against the current active node"
jenkins_build

for round in $(seq 1 "$ROUNDS"); do
    echo
    echo "== Test 1: find the active node (round ${round})"
    ACTIVE="$(active_node)"
    echo "Active node: ${ACTIVE}   (X-Served-By: $(served_by))"

    echo "== Test 1: shut it down -> docker ${MODE} ${ACTIVE}"
    T0=$(date +%s)
    docker "${MODE}" "${ACTIVE}" >/dev/null

    echo "== Test 2/3: waiting for the automatic failover of the floating IP"
    NEW=""
    for _ in $(seq 1 90); do
        NEW="$(served_by)"
        if [ -n "${NEW}" ] && [ "${NEW}" != "${ACTIVE}" ]; then break; fi
        sleep 1
    done
    echo "New active node: ${NEW:-NONE} (took ~$(( $(date +%s) - T0 ))s, no manual command)"
    ./scripts/status.sh

    echo "== Test 4: Jenkins job receives the answer from the new active node"
    jenkins_build

    # last_man_standing needs the window (10 s) to pass before the next failure
    [ "$round" -lt "$ROUNDS" ] && sleep 15
done

echo
echo "== Test 5: newest records in logs/curl.log"
tail -n $(( ROUNDS + 3 )) logs/curl.log

echo
echo "Bring nodes back with: docker start webz-001 webz-002 webz-003"
echo "(resource-stickiness=0 -> the floating IP fails back to webz-001)"
