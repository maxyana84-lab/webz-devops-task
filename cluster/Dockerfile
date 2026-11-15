FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive

# Pacemaker 1.1.18, Corosync 2.4.3, pcs 0.9.164, Apache 2.4.29 (Ubuntu 18.04 packages)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      pacemaker pacemaker-cli-utils corosync pcs resource-agents \
      apache2 curl ca-certificates \
      iproute2 iputils-ping iputils-arping procps psmisc tzdata \
 && rm -rf /var/lib/apt/lists/*

# ---- Corosync ----
COPY corosync.conf /etc/corosync/corosync.conf

# ---- Apache2 ----
# Apache is started/stopped by Pacemaker (ocf:heartbeat:apache), never by itself.
COPY apache/ports.conf          /etc/apache2/ports.conf
COPY apache/webz-vip.conf       /etc/apache2/sites-available/webz-vip.conf
COPY apache/index.html          /var/www/webz/index.html
RUN a2enmod headers status \
 && a2dissite 000-default \
 && a2ensite webz-vip \
 # Node name exposed to the vhost config as ${WEBZ_NODE} (X-Served-By header)
 && echo 'export WEBZ_NODE=$(hostname)' >> /etc/apache2/envvars \
 && mkdir -p /var/run/apache2 /var/lock/apache2

COPY entrypoint.sh         /usr/local/bin/entrypoint.sh
COPY configure-cluster.sh  /usr/local/bin/configure-cluster.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/configure-cluster.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
