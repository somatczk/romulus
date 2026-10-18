FROM myoung34/github-runner:2.336.0

# Node.js 24 LTS from the signed NodeSource apt repo (no piped setup script)
RUN apt-get update && \
    apt-get install -y curl gpg ca-certificates && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        gpg --dearmor -o /usr/share/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    corepack enable && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Amazon Corretto 25 (Java LTS)
RUN curl -fsSL https://apt.corretto.aws/corretto.key | \
    gpg --dearmor -o /usr/share/keyrings/corretto.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/corretto.gpg] https://apt.corretto.aws stable main" \
        > /etc/apt/sources.list.d/corretto.list && \
    apt-get update && \
    apt-get install -y java-25-amazon-corretto-jdk && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Maven 3.9.15
ARG MAVEN_VERSION=3.9.15
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    | tar -xz -C /opt && \
    ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

# --- Shared CI caches (volume /DATA/ci/cache -> /cache) ---
# Redirect pnpm store, Maven local repo, and the Actions tool-cache to the shared
# volume so ~60 runners stop duplicating ~4-5GB of deps into their writable layer.
# HOME=/root in this image; root home is on a read-only squashfs at runtime, but
# /root inside the image layer is writable at build time for these config files.
ENV RUNNER_TOOL_CACHE=/cache/toolcache \
    AGENT_TOOLSDIRECTORY=/cache/toolcache \
    PNPM_HOME=/cache/pnpm \
    npm_config_store_dir=/cache/pnpm
RUN printf 'store-dir=/cache/pnpm\n' > /root/.npmrc && \
    mkdir -p /root/.m2 && \
    printf '<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"><localRepository>/cache/m2</localRepository></settings>\n' > /root/.m2/settings.xml
