FROM jenkins/jenkins:2.555.1-jdk21

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    KUBECTL_VERSION=v1.33.8 \
    HELM_VERSION=v3.16.4 \
    MAVEN_VERSION=3.9.15 \
    YQ_VERSION=4.53.2 \
    NODE_MAJOR=20 \
    USE_GKE_GCLOUD_AUTH_PLUGIN=True \
    PIP_PROGRESS_BAR=off

# -----------------------
# Base + runtime tools
# -----------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git jq vim unzip \
    lsof strace \
    gnupg ca-certificates \
    python3 python3-pip python3-venv \
    postgresql-client \
    redis-tools \
    && rm -rf /var/lib/apt/lists/*

# -----------------------
# NodeJS
# -----------------------
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# -----------------------
# yq
# -----------------------
RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64 \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# -----------------------
# Python env
# -----------------------
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install -q --upgrade pip && \
    /opt/venv/bin/pip install -q requests pandas paramiko redis

ENV PATH="/opt/venv/bin:$PATH"

# -----------------------
# kubectl
# -----------------------
RUN curl -fsSL -o /usr/local/bin/kubectl \
    https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl && \
    chmod +x /usr/local/bin/kubectl

# -----------------------
# Helm
# -----------------------
RUN curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz \
    | tar xz -C /tmp && \
    mv /tmp/linux-amd64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    rm -rf /tmp/linux-amd64

# -----------------------
# Docker CLI + GCloud
# -----------------------
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list && \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/google-cloud.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    docker-ce-cli google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin && \
    rm -rf /var/lib/apt/lists/*

# -----------------------
# Maven
# -----------------------
RUN curl -fsSL https://downloads.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
    | tar xz -C /opt && \
    ln -sfn /opt/apache-maven-${MAVEN_VERSION} /opt/maven

ENV PATH="/opt/maven/bin:$PATH"

# -----------------------
# Flux + Kustomize (FIXED)
# -----------------------
RUN set -eux; \
    FLUX_VERSION=2.8.7; \
    KUSTOMIZE_VERSION=5.4.2; \
    \
    curl -fsSL https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz -o /tmp/flux.tar.gz; \
    tar -xzf /tmp/flux.tar.gz -C /tmp; \
    mv /tmp/flux /usr/local/bin/flux; \
    \
    curl -fsSL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz -o /tmp/kustomize.tar.gz; \
    tar -xzf /tmp/kustomize.tar.gz -C /tmp; \
    mv /tmp/kustomize /usr/local/bin/kustomize; \
    \
    chmod +x /usr/local/bin/flux /usr/local/bin/kustomize; \
    rm -rf /tmp/*

# -----------------------
# PostgreSQL JDBC
# -----------------------
RUN curl -fsSL https://jdbc.postgresql.org/download/postgresql-42.7.3.jar \
    -o /usr/local/lib/postgresql.jar

ENV CLASSPATH="/usr/local/lib/postgresql.jar"

# -----------------------
# Jenkins config
# -----------------------
COPY jenkins/init.groovy.d/ /usr/share/jenkins/ref/init.groovy.d/
COPY jenkins/plugins.txt /usr/share/jenkins/ref/plugins.txt

RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY jenkins/safeShutdown.sh /var/jenkins_home/safeShutdown.sh

# -----------------------
# Cleanup + permissions
# -----------------------
RUN apt-get clean && rm -rf /tmp/* /var/tmp/* && \
    if getent group docker >/dev/null 2>&1; then usermod -aG docker jenkins; fi

USER jenkins

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

ARG REVISION=unspecified