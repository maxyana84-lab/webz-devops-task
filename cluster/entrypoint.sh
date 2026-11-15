#!/bin/bash
# Runs corosync + pacemaker in the foreground (no systemd inside the container).
set -e

mkdir -p /var/log/corosync /var/log/pacemaker /var/run/apache2 /var/lock/apache2

shutdown() {
    echo "[$(hostname)] SIGTERM received - stopping pacemaker (resources move away), then corosync"
    pkill -TERM -x pacemakerd 2>/dev/null || true
    while pgrep -x pacemakerd >/dev/null; do sleep 1; done
    pkill -TERM -x corosync 2>/dev/null || true
    while pgrep -x corosync >/dev/null; do sleep 1; done
    exit 0
}
trap shutdown TERM INT

echo "[$(hostname)] starting corosync"
corosync -f &

for _ in $(seq 1 30); do
    corosync-cfgtool -s >/dev/null 2>&1 && break
    sleep 1
done

echo "[$(hostname)] starting pacemaker"
pacemakerd -f &

# Exit (and let Docker report it) if either daemon dies
wait -n
echo "[$(hostname)] a cluster daemon exited"
exit 1
