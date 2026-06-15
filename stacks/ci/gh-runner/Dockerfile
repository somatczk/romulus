FROM myoung34/github-runner:2.335.1

# Node.js 20 LTS — required before pnpm/action-setup runs
RUN apt-get update && \
    apt-get install -y curl && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
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
RUN curl -fsSL "https://downloads.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    | tar -xz -C /opt && \
    ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn
