#!/bin/bash
# Runs every test scenario from a clean state and saves the outputs to test-results/.
#   ./scripts/run-all-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT=test-results
mkdir -p "$OUT"

restore() {
    docker start webz-001 webz-002 webz-003 >/dev/null 2>&1
    # wait until the group is back on webz-001 (failback, stickiness=0)
    for _ in $(seq 1 60); do
        docker exec webz-004 curl -s -o /dev/null -D - --max-time 2 http://172.28.0.100/ \
            | grep -q "X-Served-By: webz-001" && break
        sleep 2
    done
    sleep 15   # let last_man_standing settle back to 3 expected votes
}

echo "### 0. fresh setup"
docker compose down -v >/dev/null 2>&1
rm -f logs/curl.log
./scripts/up.sh 2>&1 | grep -vE "^ *(#[0-9]|Container|Image|Network|Volume)" > "$OUT/00-setup.txt"
until docker exec webz-004 curl -s -o /dev/null --max-time 2 http://localhost:8080/login; do sleep 3; done
sleep 10

{
    echo "\$ docker compose ps"; docker compose ps --format "table {{.Name}}\t{{.Image}}\t{{.Status}}"
    echo; echo "\$ docker exec webz-001 pcs status"; docker exec webz-001 pcs status
    echo; echo "\$ docker exec webz-001 pcs constraint"; docker exec webz-001 pcs constraint
    echo; echo "\$ docker exec webz-001 crm_simulate -sL | grep allocation"
    docker exec webz-001 crm_simulate -sL 2>/dev/null | grep -E "^(group|native)_color"
    echo; echo "\$ docker exec webz-001 corosync-quorumtool -s"; docker exec webz-001 corosync-quorumtool -s
    echo; echo "\$ docker exec webz-001 ip -4 addr show eth0"; docker exec webz-001 ip -4 addr show eth0
    echo; echo "\$ docker exec webz-004 curl -i http://172.28.0.100/"; docker exec webz-004 curl -s -i http://172.28.0.100/
    echo; echo "\$ docker exec webz-004 service jenkins status"; docker exec webz-004 service jenkins status
} > "$OUT/01-cluster-status.txt" 2>&1

echo "### 1. graceful failover (docker stop)"
./scripts/failover-test.sh         > "$OUT/02-failover-docker-stop.txt" 2>&1
restore
echo "### 2. hard failover (docker kill)"
./scripts/failover-test.sh --kill  > "$OUT/03-failover-docker-kill.txt" 2>&1
restore
echo "### 3. cascade 001 -> 002 -> 003"
./scripts/failover-test.sh --cascade > "$OUT/04-failover-cascade.txt" 2>&1

echo "### 4. recovery / failback"
{
    echo "\$ docker start webz-001 webz-002"
    restore
    ./scripts/status.sh
    echo; docker exec webz-001 corosync-quorumtool -s | grep -E "Expected|Total|Quorum:|Flags"
} > "$OUT/05-recovery-failback.txt" 2>&1

echo "### 5. scheduled (timer) builds and full log"
sleep 330   # make sure at least one run was started by the 5-minute timer
{
    echo "Jenkins builds of webz-floating-ip-check (cause / result):"
    docker exec webz-004 bash -c '
        AUTH="$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD"
        curl -s -u "$AUTH" "http://localhost:8080/job/webz-floating-ip-check/api/json?tree=builds\[number,result,timestamp,actions\[causes\[shortDescription\]\]\]" \
        | grep -oE "\"shortDescription\":\"[^\"]+\"|\"number\":[0-9]+|\"result\":\"[A-Z]+\"" \
        | paste -d" " - - - | sed "s/\"//g"'
} > "$OUT/06-jenkins-builds.txt" 2>&1
cp logs/curl.log "$OUT/curl.log"

echo "done -> $OUT/"
ls -1 "$OUT"
