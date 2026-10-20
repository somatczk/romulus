# ARC runner image: GitHub's official runner plus the toolchain the org workflows expect
# (Node 24, Corretto 25, Maven, AWS CLI, GitHub CLI, docker compose). Docker comes from the dind sidecar via DOCKER_HOST.
# libatomic1: setup-node downloads Node builds (26+) that link against it.
FROM ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807

USER root

# Vendor signing keys are fetched over TLS; pin their fingerprints so a swapped key fails the build.
ARG NODESOURCE_FPR=6F71F525282841EEDAF851B42F59B5F99B1BE0B4
ARG CORRETTO_FPR=6DC3636DAE534049C8B94623A122542AB04F24E3
ARG GH_CLI_FPR=2C6106201985B60E6C7AC87323F3D4EA75716059
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl gpg ca-certificates git jq unzip zip rsync libatomic1 zstd && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        gpg --dearmor -o /usr/share/keyrings/nodesource.gpg && \
    curl -fsSL https://apt.corretto.aws/corretto.key | gpg --dearmor -o /usr/share/keyrings/corretto.gpg && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli.gpg && \
    for k in "nodesource:${NODESOURCE_FPR}" "corretto:${CORRETTO_FPR}" "githubcli:${GH_CLI_FPR}"; do \
        gpg --show-keys --with-colons "/usr/share/keyrings/${k%%:*}.gpg" | \
            awk -F: '/^fpr/{print $10; exit}' | grep -qx "${k#*:}" || { echo "bad ${k%%:*} key"; exit 1; }; \
    done && \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    echo "deb [signed-by=/usr/share/keyrings/corretto.gpg] https://apt.corretto.aws stable main" \
        > /etc/apt/sources.list.d/corretto.list && \
    echo "deb [signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs java-25-amazon-corretto-jdk gh && \
    corepack enable && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# AWS CLI v2: deploy workflows call ecs, amplify, cloudfront, secretsmanager and sts directly
ARG AWSCLI_VERSION=2.38.1
ARG AWSCLI_SHA256=b11ed416d91f4251da363a17706938eeaf0e520745754c104c0c1890dd8363c7
RUN curl -fsSLo /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" && \
    echo "${AWSCLI_SHA256}  /tmp/awscli.zip" | sha256sum -c - && \
    unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/awscli.zip /tmp/aws

# docker compose plugin: Testcontainers' ComposeContainer (vetoo-backend integration tests) shells out to it
ARG COMPOSE_VERSION=v5.6.0
ARG COMPOSE_SHA256=40343e21ca777173e69cff5dbafeb37c6f81f3b0d57d9e597f036e95eb63e76a
RUN curl -fsSLo /usr/local/lib/docker/cli-plugins/docker-compose \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" && \
    echo "${COMPOSE_SHA256}  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c - && \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

ARG MAVEN_VERSION=3.9.15
ARG MAVEN_SHA512=33d81e0ec785f0207e3e5e3ffb61863e1dca5784c15ac3fb5ff105f69cffbea484eb8d473ea60467a63f7b0570eef8622f2fed8eee96acbe668aa313391cddb3
RUN curl -fsSLo /tmp/maven.tgz "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" && \
    echo "${MAVEN_SHA512}  /tmp/maven.tgz" | sha512sum -c - && \
    tar -xzf /tmp/maven.tgz -C /opt && rm /tmp/maven.tgz && \
    ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

# Per-org cache volume is mounted at /cache (pnpm store, Maven repo, tool cache).
ENV RUNNER_TOOL_CACHE=/cache/toolcache \
    AGENT_TOOLSDIRECTORY=/cache/toolcache \
    npm_config_store_dir=/cache/pnpm \
    MAVEN_OPTS=-Dmaven.repo.local=/cache/m2 \
    TZ=Europe/Budapest

USER runner
