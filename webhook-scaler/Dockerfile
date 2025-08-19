FROM node:18-alpine

WORKDIR /app

# Install docker CLI
RUN apk add --no-cache docker-cli docker-compose curl

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm install --omit=dev && npm cache clean --force

# Copy application code
COPY . .

# Create non-root user and add to docker group
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 && \
    addgroup nodejs docker

# Change ownership of app directory
RUN chown -R nodejs:nodejs /app

USER nodejs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "server.js"]