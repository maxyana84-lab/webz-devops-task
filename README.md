# Junior DevOps Engineer – Home Task (webz.io)

Four Ubuntu 18.04 containers:

| Container | IP | Role |
|---|---|---|
| webz-001 | 172.28.0.11 | Pacemaker/Corosync node, **active** (preferred) |
| webz-002 | 172.28.0.12 | Pacemaker/Corosync node, 1st standby |
| webz-003 | 172.28.0.13 | Pacemaker/Corosync node, 2nd standby |
| webz-004 | 172.28.0.14 | Jenkins (not in the cluster) |
| **Floating IP** | **172.28.0.100** | Moves between webz-001..003, Apache listens on it |

```
                 docker bridge "webz-net" 172.28.0.0/24
   ┌──────────────┬──────────────┬──────────────┬──────────────┐
   │ webz-001     │ webz-002     │ webz-003     │ webz-004     │
   │ corosync     │ corosync     │ corosync     │ Jenkins      │
   │ pacemaker    │ pacemaker    │ pacemaker    │ job */5 min  │
   │ [VIP .100]   │              │              │ curl VIP:80  │
   │ [apache2]    │              │              │  >> curl.log │
   └──────────────┴──────────────┴──────────────┴──────┬───────┘
         score 100      score 50       score 25        │ bind mount
                                                       ▼
                                              host: ./logs/curl.log
```

## Repository layout

```
docker-compose.yml          4 containers, static IPs, network, volumes
cluster/
  Dockerfile                ubuntu:18.04 + pacemaker, corosync, pcs, apache2
  corosync.conf             3-node udpu ring, votequorum
  entrypoint.sh             runs corosync + pacemakerd (no systemd in containers)
  configure-cluster.sh      creates resources, constraints, properties (pcs)
  apache/ports.conf         Listen 172.28.0.100:80 (+127.0.0.1 for health check)
  apache/webz-vip.conf      VirtualHost on the floating IP, X-Served-By header
  apache/index.html         "Junior DevOps Engineer - Home Task"
jenkins/
  Dockerfile                ubuntu:18.04 + OpenJDK 17 + Jenkins LTS (official WAR)
  jenkins.init / .default   SysV service: `service jenkins start|stop|status`
  entrypoint.sh             starts the Jenkins service
  curl-check.sh             body of the Jenkins job
  init.groovy.d/            admin user + job created automatically on start
scripts/
  up.sh                     build, start, configure cluster
  status.sh                 which node is active
  failover-test.sh          tests 1-5
logs/curl.log               Jenkins job output, visible on the host
```

## How to run

Requirements: Linux / WSL2 with Docker Engine + Docker Compose v2.

```bash
./scripts/up.sh             # build + start + configure cluster
./scripts/status.sh         # who is active
./scripts/failover-test.sh            # tests 1-5, graceful stop of the active node
./scripts/failover-test.sh --kill     # same with a hard failure (docker kill)
./scripts/failover-test.sh --cascade  # two failures in a row: 001 -> 002 -> 003
docker start webz-001 webz-002 webz-003   # bring nodes back
docker compose down -v      # remove everything
tail -f logs/curl.log       # the Jenkins log, from the host
```

Jenkins UI: http://localhost:8090 (admin / admin by default). Override with
`JENKINS_ADMIN_USER`, `JENKINS_ADMIN_PASSWORD`, `JENKINS_HOST_PORT` in `.env`.

---

## Step-by-step documentation

### 1. Four containers (docker-compose.yml)

* Image `ubuntu:18.04`, `container_name` and `hostname` = `webz-00X`.
* A dedicated bridge network `172.28.0.0/24` with static addresses.
  `ip_range: 172.28.0.0/26` limits Docker's own allocation to .0–.63, so the
  floating IP `172.28.0.100` can never be given to a container.
* Cluster nodes get `NET_ADMIN` + `NET_RAW` (to add the VIP to `eth0` and send
  gratuitous ARP) and `SYS_NICE` + `IPC_LOCK` (corosync realtime scheduling).
  No `--privileged` is needed.
* `shm_size: 256m` – corosync/pacemaker (libqb) keep IPC ring buffers in
  `/dev/shm`; Docker's default 64 MB filled up during testing.
* `extra_hosts` gives every cluster node a static `/etc/hosts` entry for its
  peers, so corosync can resolve `webz-00X` even while a peer container is
  stopped (Docker's embedded DNS forgets stopped containers).
* systemd does not run reliably in an Ubuntu 18.04 container on a cgroup v2
  host (systemd 237), so `entrypoint.sh` starts `corosync -f` and
  `pacemakerd -f` directly and stops them gracefully on SIGTERM.

### 2. Pacemaker + Corosync floating IP cluster (webz-001..003)

Packages: `pacemaker corosync pcs resource-agents`.

`/etc/corosync/corosync.conf` – a static 3-node ring over unicast UDP
(`transport: udpu`; multicast is not guaranteed on Docker bridges), node names
equal to the hostnames, `corosync_votequorum` (3 votes → quorum 2).

Resources (`cluster/configure-cluster.sh`, run once on any node – the CIB is
replicated):

```bash
pcs property set stonith-enabled=false      # no fencing devices in containers
pcs property set no-quorum-policy=stop      # an isolated node stops its resources
pcs resource defaults resource-stickiness=0

pcs resource create FloatingIP ocf:heartbeat:IPaddr2 \
    ip=172.28.0.100 cidr_netmask=24 nic=eth0 op monitor interval=5s --group WebGroup
pcs resource create WebServer ocf:heartbeat:apache \
    configfile=/etc/apache2/apache2.conf statusurl="http://127.0.0.1/server-status" \
    op monitor interval=10s --group WebGroup

pcs constraint location WebGroup prefers webz-001=100 webz-002=50 webz-003=25
```

**Active server and failover order.** The location scores decide it:
**webz-001 (100) is active → webz-002 (50) → webz-003 (25)**.
Pacemaker always places `WebGroup` on the online node with the highest score.
With `resource-stickiness=0` the IP *fails back* to webz-001 when it returns;
setting stickiness above 100 (e.g. `pcs resource defaults resource-stickiness=200`)
would keep it where it is and avoid a second short outage.

The resource **group** gives both colocation (IP and Apache on the same node)
and ordering (IP is added before Apache starts, Apache stops before the IP is
removed).

Allocation scores as computed by Pacemaker (`crm_simulate -sL`):

```
group_color: WebGroup allocation score on webz-001: 100
group_color: WebGroup allocation score on webz-002: 50
group_color: WebGroup allocation score on webz-003: 25
```

**Quorum – making the whole chain 001 → 002 → 003 work.** With plain
votequorum (3 votes, quorum 2), after *two* failures webz-003 is alone with
1/3 votes, loses quorum and `no-quorum-policy=stop` keeps the VIP down – the
3rd server in the order would never become active. This was reproduced, so the
`quorum {}` section of `corosync.conf` adds:

```
wait_for_all: 1               # cold start: quorum only after all 3 nodes were seen
last_man_standing: 1          # node gone for 10 s -> expected_votes 3 -> 2
last_man_standing_window: 10000
auto_tie_breaker: 1           # 1-of-2 split: the side with the tie-breaker node wins
auto_tie_breaker_node: highest  # = webz-003, the last node of the chain
```

Notes from testing on corosync 2.4.3:
* LMS + ATB without `wait_for_all` is rejected (corosync exits with code 20).
* `auto_tie_breaker_node: lowest` or a list `1 2 3` also count dead nodes, so
  webz-003 stayed without quorum; `highest` works.
* Trade-off: the chain survives failures *one after another in priority
  order*. If webz-003 itself is one of the two failed nodes, the last survivor
  stops the VIP (safe behaviour – no split-brain). Proper fix: corosync-qdevice
  (see suggestions).

### 3. Apache2 on the floating IP

* `ports.conf`: `Listen 172.28.0.100:80` (+ `127.0.0.1:80`, used only by the
  Pacemaker health check `server-status`).
* VirtualHost `webz-vip.conf` is bound to `172.28.0.100:80`, document root
  `/var/www/webz`, homepage text **"Junior DevOps Engineer - Home Task"**.
* Apache is **managed by Pacemaker** (`ocf:heartbeat:apache`), so it runs only
  on the node that currently holds the VIP – binding to the VIP never fails
  and Pacemaker restarts/moves Apache if its monitor fails.
* The vhost adds a response header `X-Served-By: <hostname>`
  (`WEBZ_NODE=$(hostname)` is exported in `/etc/apache2/envvars`). The page
  text stays exactly as required, and Jenkins can still tell which container
  answered.

### 4. Jenkins on webz-004

* OpenJDK 17 (bionic-updates) + Jenkins LTS **2.479.3**, pinned.
  The official `.deb` from pkg.jenkins.io cannot be installed on 18.04
  (`PreDepends: init-system-helpers (>= 1.54~)`, bionic has 1.51), so the
  official `jenkins.war` is downloaded, verified with SHA-256 and installed as a
  SysV service (`/etc/init.d/jenkins`, `/etc/default/jenkins`):
  `service jenkins start|stop|restart|status`.
* The setup wizard is skipped; `init.groovy.d/01-security.groovy` creates the
  admin user, `02-job.groovy` creates the freestyle job
  **`webz-floating-ip-check`** with trigger `H/5 * * * *` (every 5 minutes)
  and a single shell step = `jenkins/curl-check.sh`.
* Every run **appends** (`>>`) one line to `/var/log/webz/curl.log`:
  ```
  2026-11-15 14:05:02 IST | node=webz-001 | http=200 | curl_rc=0 | Junior DevOps Engineer - Home Task
  ```
  run time, container that answered, HTTP code, curl exit code, page output.
* `/var/log/webz` is a bind mount of `./logs` → the log is readable on the host.
  The `jenkins` user has UID 1000, so the file is owned by the host user too.

---

## Tests

All tests are automated in `scripts/failover-test.sh`. Output below is from a
fresh `docker compose down -v && ./scripts/up.sh` run (trimmed).

### Test 1 – find the active node and shut it down

```
$ docker exec webz-001 pcs status
Online: [ webz-001 webz-002 webz-003 ]
 Resource Group: WebGroup
     FloatingIP	(ocf::heartbeat:IPaddr2):	Started webz-001
     WebServer	(ocf::heartbeat:apache):	Started webz-001

$ docker exec webz-001 ip -4 addr show eth0 | grep inet
    inet 172.28.0.11/24 brd 172.28.0.255 scope global eth0
    inet 172.28.0.100/24 brd 172.28.0.255 scope global secondary eth0

$ docker kill webz-001        # hard failure   (or: docker stop webz-001)
```

Other ways to see the active node: `crm_resource --resource FloatingIP --locate`,
`crm_mon -1`, or the `X-Served-By` header of `curl -I http://172.28.0.100/`.

### Test 2 – the floating IP moves to another machine

```
== Test 1: shut it down -> docker kill webz-001
New active node: webz-002 (took ~11s, no manual command)
 Resource Group: WebGroup
     FloatingIP	(ocf::heartbeat:IPaddr2):	Started webz-002
     WebServer	(ocf::heartbeat:apache):	Started webz-002
X-Served-By: webz-002

== Test 1: shut it down -> docker kill webz-002        (--cascade, 2nd failure)
New active node: webz-003 (took ~10s, no manual command)
     FloatingIP	(ocf::heartbeat:IPaddr2):	Started webz-003
X-Served-By: webz-003
```

With `docker stop` (graceful) pacemaker on the stopping node migrates the
group itself – failover took ~6 s.

### Test 3 – automatic or manual?

**Automatic.** No command is needed. How it works:

1. Corosync detects the missing node after the totem `token` timeout
   (`token: 3000` ms in `corosync.conf`) and a new membership is formed.
2. Votequorum confirms the remaining partition still has quorum
   (2 of 3; then LMS + ATB for the last node – see section 2).
3. Pacemaker recomputes placement from the location scores
   (`webz-001=100, webz-002=50, webz-003=25`) and, in group order, runs
   `IPaddr2 start` (adds the VIP + sends gratuitous ARP so webz-004 updates its
   ARP cache) and then `apache start`.
4. Monitors (`FloatingIP` every 5 s, `WebServer` every 10 s) also restart or
   move the group if only Apache dies while the node stays up.

Relevant configuration:

```bash
pcs resource create FloatingIP ocf:heartbeat:IPaddr2 ip=172.28.0.100 cidr_netmask=24 \
    nic=eth0 op monitor interval=5s --group WebGroup
pcs resource create WebServer ocf:heartbeat:apache configfile=/etc/apache2/apache2.conf \
    statusurl="http://127.0.0.1/server-status" op monitor interval=10s --group WebGroup
pcs constraint location WebGroup prefers webz-001=100 webz-002=50 webz-003=25
pcs resource defaults resource-stickiness=0
pcs property set stonith-enabled=false no-quorum-policy=stop
```

**Manual commands** (planned maintenance / moving it on purpose):

```bash
pcs resource move WebGroup webz-003   # adds a temporary INFINITY location constraint
pcs resource clear WebGroup           # removes it -> back to normal scores
pcs node standby webz-001             # drain a node (resources leave it)
pcs node unstandby webz-001
pcs resource cleanup WebGroup         # clear failure counts after a failed start
```

### Test 4 – the Jenkins job gets a response from the active machine

The job runs every 5 minutes by itself; the test script additionally queues it
through the REST API so results do not depend on waiting:

```
== Test 4: Jenkins job receives the answer from the new active node
Jenkins build queued: HTTP 201
--- console of the last build ---
Started by user admin
--- last records in /var/log/webz/curl.log ---
2026-11-15 20:07:51 IST | node=webz-003 | http=200 | curl_rc=0 | Junior DevOps Engineer - Home Task
Finished: SUCCESS
```

If the VIP does not answer, curl's exit code makes the build **FAILURE**, so a
broken cluster is visible in Jenkins as red builds.

### Test 5 – new records contain the name of the new active machine

`logs/curl.log` on the host (records are appended, never overwritten):

```
2026-11-15 20:06:01 IST | node=unknown  | http=000 | curl_rc=7 | curl: (7) Failed to connect to 172.28.0.100 port 80: No route to host
2026-11-15 20:06:46 IST | node=webz-001 | http=200 | curl_rc=0 | Junior DevOps Engineer - Home Task
2026-11-15 20:07:11 IST | node=webz-002 | http=200 | curl_rc=0 | Junior DevOps Engineer - Home Task
2026-11-15 20:07:51 IST | node=webz-003 | http=200 | curl_rc=0 | Junior DevOps Engineer - Home Task
```

The first line is a scheduled run that fired while the stack was starting,
before `configure-cluster.sh` created the VIP – an example of how an outage
looks in the log.

### Recovery / failback

```
$ docker start webz-001 webz-002
 Resource Group: WebGroup
     FloatingIP	(ocf::heartbeat:IPaddr2):	Started webz-001
X-Served-By: webz-001
Expected votes:   3
Total votes:      3
Flags:            Quorate WaitForAll LastManStanding AutoTieBreaker
```

---

## Problems met and how they were solved

| Problem | Solution |
|---|---|
| systemd 237 (Ubuntu 18.04) does not run in a container on a cgroup v2 host | `entrypoint.sh` runs `corosync -f` and `pacemakerd -f` directly, graceful stop on SIGTERM |
| `crm_mon` missing | `pacemaker-cli-utils` is only a Recommends of `pacemaker` → installed explicitly |
| `pcs status`: *corosync and pacemaker node names do not match* | `ring0_addr` uses hostnames + static `extra_hosts` |
| Apache cannot bind the VIP on standby nodes | Apache is a Pacemaker resource in the same group, started only after the VIP |
| Jenkins `.deb` needs `init-system-helpers >= 1.54` (bionic: 1.51) | official WAR + SHA-256 check + SysV init script |
| pkg.jenkins.io signing key rotated (`jenkins.io-2023.key` → `2026`) | removed the apt repo altogether (WAR install) |
| Last node of the chain had no quorum after 2 failures | `last_man_standing` + `auto_tie_breaker_node: highest` + `wait_for_all` |
| `No space left on device` in `/dev/shm` (libqb) | `shm_size: 256m` |
| Host ports 8080/8081 already used | Jenkins published on `8090`, configurable via `JENKINS_HOST_PORT` |
| Page `<title>` leaked into the log line | job strips `<head>` before removing tags |

---

## Suggestions for improvement

**Platform / OS**
* Ubuntu 18.04 is end-of-life (standard support ended 2023). Move to 22.04/24.04:
  current Pacemaker 2.1 / Corosync 3 (knet transport, multiple links,
  encryption), `pcs` 0.11, and the official Jenkins packages work again.
* Running a Pacemaker cluster *inside containers on one host* is useful for
  learning but gives no real HA: one host = one failure domain. Real nodes
  should be VMs/hosts in different racks/zones.

**High availability**
* Enable **STONITH/fencing** (IPMI, `fence_aws`, `fence_vmware`, …).
  Without fencing a hung node can still hold the VIP → split-brain.
* Replace the LMS/ATB tuning with **corosync-qdevice + qnetd** on a 4th
  machine (e.g. webz-004): an external arbiter vote handles any 2-node
  failure correctly.
* Choose stickiness on purpose: `resource-stickiness=0` gives automatic
  failback (and a second short outage); in production a value > 100 is often
  preferred, with failback done manually in a maintenance window.
* For "one VIP + a web server" **keepalived (VRRP)** is much simpler than
  Pacemaker; in the cloud use the provider's load balancer / floating IP API;
  in Kubernetes a `Service` + readiness probes (and MetalLB on bare metal).
* Active-active instead of active-passive: HAProxy/Nginx in front of all three
  Apache nodes would use all servers and avoid failover time completely.

**Jenkins**
* Configuration as Code (JCasC) + Job DSL / a `Jenkinsfile` in git instead of
  init Groovy scripts; pin plugins with `plugins.txt`.
* Run jobs on agents, not on the controller; manage credentials in the
  Jenkins credential store / a vault, never as default `admin/admin`.
* Use the official `jenkins/jenkins:lts` image instead of a hand-made one.
* For a pure health check a cron job, a systemd timer, or a monitoring
  system (Prometheus blackbox exporter, Uptime Kuma) is lighter than Jenkins.

**Logging & monitoring**
* Write structured logs (JSON), rotate them (`logrotate`), ship them to
  ELK / Loki instead of a local file.
* Alert on failures: Jenkins email/Slack notifications on a FAILURE build, or
  Prometheus alerts on `probe_success == 0` and on Pacemaker failcounts
  (`ha_cluster_exporter`).

**Automation & security**
* Provision the nodes with **Ansible** (roles for corosync/pacemaker/apache)
  so the same code works on containers, VMs and bare metal.
* Turn on corosync authentication/encryption (`crypto_cipher`, `authkey`),
  restrict the Jenkins UI, add TLS to Apache.
* CI for this repository: `hadolint` for Dockerfiles, `shellcheck` for
  scripts, and the failover test as an automated pipeline.
