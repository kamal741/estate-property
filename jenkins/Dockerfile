FROM jenkins/jenkins:2.555.1-jdk21

# Build from repository root (see README):
#   docker build -f jenkins/Dockerfile -t <registry>/estate-property/jenkins:<tag> .
# COPY paths are relative to that context (.), not this file's directory.

USER root

ENV KUBECTL_VERSION=v1.33.8
ENV REDIS_VERSION=7.2.5
ENV HELM_VERSION=v3.16.4
ENV MAVEN_VERSION=3.9.15

# -----------------------
# Base tools (simplified)
# -----------------------
RUN apt-get update && apt-get install -y \
    curl wget git jq vim lsof strace unzip \
    gnupg nodejs python3-pip python3-venv postgresql-client \
    make gcc g++ build-essential \
    && rm -rf /var/lib/apt/lists/*

# -----------------------
# NodeJS repo
# -----------------------
ENV NODE_MAJOR=16

RUN mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
     | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
     > /etc/apt/sources.list.d/nodesource.list

# -----------------------
# Adoptium repo
# -----------------------
RUN curl -sSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | tee /etc/apt/keyrings/adoptium.asc \
  && echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb \
     $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" \
     > /etc/apt/sources.list.d/adoptium.list

# -----------------------
# Install tools
# -----------------------
RUN apt-get update && apt-get install -y nodejs jq vim wget unzip \
    && rm -rf /var/lib/apt/lists/*

# -----------------------
# yq (PUBLIC)
# -----------------------
RUN wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    -O /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# -----------------------
# Python libs
# -----------------------
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --upgrade pip && \
    /opt/venv/bin/pip install requests pandas paramiko redis

ENV PATH="/opt/venv/bin:$PATH"

# -----------------------
# SSH tuning
# -----------------------
RUN echo "ServerAliveInterval 60" >> /etc/ssh/ssh_config && \
    echo "ServerAliveCountMax 180" >> /etc/ssh/ssh_config

# -----------------------
# PostgreSQL JDBC
# -----------------------
ENV POSTGRES_VERSION=42.7.3

RUN wget https://jdbc.postgresql.org/download/postgresql-${POSTGRES_VERSION}.jar \
    -O /usr/local/lib/postgresql.jar

ENV CLASSPATH="/usr/local/lib/postgresql.jar"

# -----------------------
# kubectl (PUBLIC)
# -----------------------
RUN curl -L -o /usr/local/bin/kubectl \
    https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl && \
    chmod +x /usr/local/bin/kubectl

# -----------------------
# Helm (PUBLIC) — k8s/scripts/deploy.sh, Pipeline_Deploy
# -----------------------
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm -rf /tmp/linux-amd64

# -----------------------
# Docker CLI + Google Cloud SDK (apt) — Pipeline_Deploy build/push + gcloud auth
# -----------------------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/google-cloud.gpg \
    && chmod a+r /etc/apt/keyrings/google-cloud.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

# -----------------------
# Apache Maven — EstateFlow verify scripts / mvn pipelines
# -----------------------
RUN curl -fsSL "https://downloads.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    | tar xz -C /opt \
    && ln -sfn "/opt/apache-maven-${MAVEN_VERSION}" /opt/maven

ENV PATH="/opt/maven/bin:/opt/venv/bin:$PATH"

# Jenkins user can use host Docker socket when mounted (group on node must match or use rootless)
RUN if getent group docker >/dev/null 2>&1; then usermod -aG docker jenkins; fi

# -----------------------
# flux CLI
# -----------------------
RUN curl -s https://fluxcd.io/install.sh | bash

# -----------------------
# kustomize
# -----------------------
RUN curl -s https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh \
    | bash -s /usr/local/bin

# -----------------------
# Redis CLI
# -----------------------
RUN cd /tmp && \
    curl -L -o redis.tar.gz https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz && \
    tar xzf redis.tar.gz && \
    make -j2 -C redis-${REDIS_VERSION} && \
    cp redis-${REDIS_VERSION}/src/redis-cli /usr/local/bin && \
    rm -rf /tmp/redis*

# -----------------------
# Cleanup
# -----------------------
RUN apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# -----------------------
# Jenkins user
# -----------------------
USER jenkins

# When the container does not override JAVA_OPTS, still skip the GUI setup wizard on first boot.
# Helm should pass full javaOpts (including this flag); this is the image fallback for docker run, etc.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

# -----------------------
# Jenkins config (paths are under jenkins/ — build context must be repo root, see cloudbuild.yaml)
# -----------------------
COPY jenkins/init.groovy.d/ /usr/share/jenkins/ref/init.groovy.d/
#COPY jenkins/init.jcasc/ /usr/share/jenkins/ref/init.jcasc/
COPY jenkins/plugins.txt /usr/share/jenkins/ref/plugins.txt

RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY jenkins/safeShutdown.sh /var/jenkins_home/safeShutdown.sh

# -----------------------
# Metadata
# -----------------------
ARG REVISION=unspecified