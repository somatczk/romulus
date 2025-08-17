#!/bin/bash

# Service Restart Script for Vault Agent
# 
# Purpose: Restart services when secrets are updated
# Triggered: When Vault Agent renders new templates

set -euo pipefail

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
}

# Copy new .env file to project root
if [[ -f "/vault/agent/.env" ]]; then
    log_info "Updating .env file from Vault secrets"
    cp "/vault/agent/.env" "/workspace/.env"
    chmod 600 "/workspace/.env"
    log_info "Updated .env file successfully"
else
    log_error ".env template not found"
    exit 1
fi

# Restart services that depend on environment variables
SERVICES_TO_RESTART=(
    "mariadb"
    "redis" 
    "grafana"
    "authelia"
    "caddy"
)

log_info "Restarting services with updated secrets..."

cd /workspace

for service in "${SERVICES_TO_RESTART[@]}"; do
    if docker-compose ps "$service" 2>/dev/null | grep -q "Up"; then
        log_info "Restarting $service..."
        docker-compose restart "$service"
    else
        log_info "Service $service not running, skipping restart"
    fi
done

log_info "Service restart completed"

# Send notification if webhook is configured
if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
    curl -X POST "$DISCORD_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d '{
            "embeds": [{
                "title": "Vault Secret Update",
                "description": "Services restarted with updated secrets from Vault",
                "color": 3066993,
                "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
            }]
        }' 2>/dev/null || log_info "Discord notification failed"
fi