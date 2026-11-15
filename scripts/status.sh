#!/bin/bash
# Which node is active right now? Run from the host.
set -u
for n in webz-001 webz-002 webz-003; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = "true" ]; then
        docker exec "$n" crm_mon -1 -r 2>/dev/null | sed -n '/Full list of resources/,$p'
        break
    fi
done
echo
echo "Responding node (via webz-004):"
docker exec webz-004 curl -s -o /dev/null -D - --max-time 5 http://172.28.0.100/ | grep -i x-served-by || echo "no answer"
