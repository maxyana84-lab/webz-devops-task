FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive \
    JENKINS_HOME=/var/lib/jenkins

# Jenkins LTS pinned to a release that runs on Java 17 (available in bionic-updates).
# The official .deb cannot be used on 18.04: it pre-depends on
# init-system-helpers >= 1.54 (bionic has 1.51). The official WAR is installed
# instead (checksum-verified) and wrapped in a SysV init service.
ARG JENKINS_VERSION=2.479.3
ARG JENKINS_SHA256=304c8592860d5b03dec27c96b5e89ec58fc744f78161c53f7a344a0bf7ce9203

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openjdk-17-jre-headless fontconfig \
      curl ca-certificates git tzdata iputils-ping procps \
 && rm -rf /var/lib/apt/lists/*

# Jenkins user with UID 1000 so that the bind-mounted log file is owned by the
# host user (outside the container) as well.
RUN groupadd -g 1000 jenkins \
 && useradd -u 1000 -g jenkins -d /var/lib/jenkins -s /bin/bash jenkins \
 && mkdir -p /usr/share/java /var/log/jenkins /var/lib/jenkins \
 && curl -fsSL -o /usr/share/java/jenkins.war \
      "https://get.jenkins.io/war-stable/${JENKINS_VERSION}/jenkins.war" \
 && echo "${JENKINS_SHA256}  /usr/share/java/jenkins.war" | sha256sum -c - \
 && chown -R jenkins:jenkins /var/log/jenkins /var/lib/jenkins

COPY jenkins.default  /etc/default/jenkins
COPY jenkins.init     /etc/init.d/jenkins
COPY curl-check.sh    /opt/webz/curl-check.sh
COPY init.groovy.d/   /opt/webz/init.groovy.d/
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod +x /etc/init.d/jenkins /opt/webz/curl-check.sh /usr/local/bin/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
