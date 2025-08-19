FROM node:18-slim

WORKDIR /app

# Install docker CLI and docker-compose
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        docker.io \
        docker-compose-plugin \
        curl \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    # Create docker-compose symlink for compatibility
    ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm install --omit=dev && npm cache clean --force

# Copy application code
COPY . .

# Create non-root user for development, but allow running as root for Docker access
RUN groupadd -g 1001 nodejs && \
    useradd -r -u 1001 -g nodejs nodejs

# Change ownership of app directory (support both root and nodejs user)
RUN chown -R nodejs:nodejs /app && \
    chmod -R 755 /app

# Default to nodejs user, but allow override via docker-compose user directive
USER nodejs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "server.js"]