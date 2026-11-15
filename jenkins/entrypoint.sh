#!/bin/bash
# Container PID 1: prepares files, starts the Jenkins service, keeps running
# while it is alive and stops it gracefully on `docker stop`.
set -e

mkdir -p /var/log/webz /var/log/jenkins "$JENKINS_HOME/init.groovy.d"
touch /var/log/webz/curl.log /var/log/jenkins/jenkins.log
chown jenkins:jenkins /var/log/webz /var/log/webz/curl.log /var/log/jenkins/jenkins.log
chmod 644 /var/log/webz/curl.log

# Init scripts (admin user + job) are re-applied on every start; they are idempotent
cp /opt/webz/init.groovy.d/*.groovy "$JENKINS_HOME/init.groovy.d/"
chown -R jenkins:jenkins "$JENKINS_HOME"

# `service` runs init scripts with a clean environment -> pass TZ via the defaults file
sed -i '/^TZ=/d' /etc/default/jenkins
echo "TZ=${TZ:-UTC}" >> /etc/default/jenkins

trap 'service jenkins stop; exit 0' TERM INT

service jenkins start
tail -n +1 -F /var/log/jenkins/jenkins.log &

while service jenkins status >/dev/null; do sleep 5 & wait $!; done
echo "jenkins exited"
exit 1
