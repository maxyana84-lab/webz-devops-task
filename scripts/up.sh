#!/bin/bash
# Build + start all 4 containers and configure the Pacemaker resources.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose up -d --build
docker exec webz-001 configure-cluster.sh

echo
echo "Jenkins:  http://localhost:${JENKINS_HOST_PORT:-8090}  (user: ${JENKINS_ADMIN_USER:-admin})"
echo "Log file: $(pwd)/logs/curl.log"
echo "Quick check from webz-004:"
docker exec webz-004 curl -s -i http://172.28.0.100/ | grep -E 'HTTP/|X-Served-By|<h1>'
