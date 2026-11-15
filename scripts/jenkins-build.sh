#!/bin/bash
# Trigger the Jenkins job through the REST API, wait for that exact build and
# print its console. Exit code: 0 if the build result is SUCCESS.
#   ./scripts/jenkins-build.sh
set -euo pipefail

docker exec webz-004 bash -c '
    J=http://localhost:8080; JOB=webz-floating-ip-check
    AUTH="$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD"; JAR=$(mktemp)
    CRUMB=$(curl -s -c "$JAR" -u "$AUTH" "$J/crumbIssuer/api/json" \
            | sed -E "s/.*\"crumb\":\"([^\"]+)\".*\"crumbRequestField\":\"([^\"]+)\".*/\2:\1/")
    N=$(curl -s -u "$AUTH" "$J/job/$JOB/api/json?tree=nextBuildNumber" | grep -oE "[0-9]+")
    curl -s -b "$JAR" -u "$AUTH" -H "$CRUMB" -X POST "$J/job/$JOB/build" -o /dev/null \
         -w "Jenkins build #$N queued: HTTP %{http_code}\n"
    for _ in $(seq 1 60); do
        curl -s -u "$AUTH" "$J/job/$JOB/$N/api/json?tree=building" | grep -q "\"building\":false" && break
        sleep 2
    done
    echo "--- console of build #$N ---"
    curl -s -u "$AUTH" "$J/job/$JOB/$N/consoleText" | grep -vE "^\[|^Running|^Building"
    curl -s -u "$AUTH" "$J/job/$JOB/$N/api/json?tree=result" | grep -q "\"result\":\"SUCCESS\""'
