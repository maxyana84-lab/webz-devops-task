#!/bin/bash
# One-time cluster resource configuration. Run on ANY one node, e.g.:
#   docker exec webz-001 configure-cluster.sh
# The CIB is replicated by pacemaker to all nodes. Safe to re-run.
set -euo pipefail

VIP=172.28.0.100

echo ">> waiting for all 3 nodes to be online with quorum"
for _ in $(seq 1 60); do
    if crm_mon -1 2>/dev/null | grep -q "partition with quorum" \
       && crm_mon -1 2>/dev/null | grep -Eq "Online: \[ webz-001 webz-002 webz-003 \]"; then
        break
    fi
    sleep 2
done
crm_mon -1 | head -n 12

echo ">> cluster properties"
# No fencing devices exist in containers (in production STONITH is mandatory)
pcs property set stonith-enabled=false
# 3 nodes: if a node is left alone without quorum, it stops its resources (no split-brain)
pcs property set no-quorum-policy=stop
# stickiness 0 => the VIP always runs on the highest-scored online node,
# i.e. it moves back to webz-001 when it recovers (automatic failback)
pcs resource defaults resource-stickiness=0

if ! pcs resource show WebGroup >/dev/null 2>&1; then
    echo ">> creating resources (group = colocation + start order: IP first, then Apache)"
    pcs resource create FloatingIP ocf:heartbeat:IPaddr2 \
        ip=${VIP} cidr_netmask=24 nic=eth0 \
        op monitor interval=5s \
        --group WebGroup
    pcs resource create WebServer ocf:heartbeat:apache \
        configfile=/etc/apache2/apache2.conf \
        statusurl="http://127.0.0.1/server-status" \
        op monitor interval=10s timeout=20s \
        --group WebGroup
fi

echo ">> failover order: webz-001 (active) -> webz-002 -> webz-003"
pcs constraint location WebGroup prefers webz-001=100 webz-002=50 webz-003=25

echo ">> done"
sleep 5
pcs status
pcs constraint
