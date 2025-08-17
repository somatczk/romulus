#!/bin/bash

# HashiCorp Vault Setup Script
# 
# Purpose: Initialize and configure Vault for secret management
# Usage: ./scripts/setup-vault.sh
# 
# This script:
# 1. Starts Vault server
# 2. Initializes and unseals Vault
# 3. Configures authentication methods
# 4. Sets up secret engines
# 5. Creates policies and roles
# 6. Configures Vault Agent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_DIR="$PROJECT_DIR/configs/vault"
DATA_DIR="${SSD_PATH:-./data}/vault"

log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

log_error() {
    echo "[ERROR] $1"
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    if ! command -v docker-compose &> /dev/null; then
        log_error "docker-compose is required"
        exit 1
    fi
    
    if ! command -v vault &> /dev/null; then
        log_info "Installing Vault CLI..."
        # Install Vault CLI for setup
        curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add - 2>/dev/null || true
        curl -fsSL https://releases.hashicorp.com/vault/1.15.4/vault_1.15.4_linux_amd64.zip -o /tmp/vault.zip
        unzip -o /tmp/vault.zip -d /tmp/
        sudo mv /tmp/vault /usr/local/bin/
        rm /tmp/vault.zip
    fi
    
    log_success "Dependencies ready"
}

start_vault_server() {
    log_info "Starting Vault server..."
    
    # Create required directories
    mkdir -p "$DATA_DIR"/{data,logs,agent,policies}
    
    # Set proper permissions
    chmod 755 "$VAULT_DIR/agent/restart-services.sh"
    
    # Start Vault service
    cd "$PROJECT_DIR"
    docker-compose -f docker-compose.yml -f docker-compose.vault.yml up -d vault
    
    # Wait for Vault to be ready
    log_info "Waiting for Vault to start..."
    for i in {1..30}; do
        if curl -s http://localhost:8200/v1/sys/health >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    
    export VAULT_ADDR="http://localhost:8200"
    log_success "Vault server started"
}

initialize_vault() {
    log_info "Initializing Vault..."
    
    # Check if already initialized
    if vault status 2>/dev/null | grep -q "Initialized.*true"; then
        log_info "Vault already initialized"
        return 0
    fi
    
    # Initialize Vault with 5 key shares, threshold of 3
    vault operator init -key-shares=5 -key-threshold=3 -format=json > "$DATA_DIR/vault-init.json"
    
    # Extract keys and token
    UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' "$DATA_DIR/vault-init.json")
    UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' "$DATA_DIR/vault-init.json")
    UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' "$DATA_DIR/vault-init.json")
    ROOT_TOKEN=$(jq -r '.root_token' "$DATA_DIR/vault-init.json")
    
    # Unseal Vault
    vault operator unseal "$UNSEAL_KEY_1"
    vault operator unseal "$UNSEAL_KEY_2"
    vault operator unseal "$UNSEAL_KEY_3"
    
    # Authenticate with root token
    vault auth "$ROOT_TOKEN"
    
    # Store root token for later use
    echo "$ROOT_TOKEN" > "$DATA_DIR/root-token.txt"
    chmod 600 "$DATA_DIR/root-token.txt"
    
    log_success "Vault initialized and unsealed"
    
    echo
    echo "IMPORTANT: Save these unseal keys securely!"
    echo "Unseal Key 1: $UNSEAL_KEY_1"
    echo "Unseal Key 2: $UNSEAL_KEY_2" 
    echo "Unseal Key 3: $UNSEAL_KEY_3"
    echo "Root Token: $ROOT_TOKEN"
    echo
}

setup_secret_engines() {
    log_info "Setting up secret engines..."
    
    # Authenticate with root token
    ROOT_TOKEN=$(cat "$DATA_DIR/root-token.txt")
    vault auth "$ROOT_TOKEN"
    
    # Enable KV v2 secret engine
    vault secrets enable -version=2 -path=kv kv
    
    log_success "Secret engines configured"
}

setup_authentication() {
    log_info "Setting up authentication methods..."
    
    # Enable AppRole auth method
    vault auth enable approle
    
    # Create policy for homeserver services
    cat > "$DATA_DIR/homeserver-policy.hcl" << 'EOF'
# Homeserver service policy
path "kv/data/homeserver/*" {
  capabilities = ["read"]
}

path "kv/metadata/homeserver/*" {
  capabilities = ["read", "list"]
}

# Allow token renewal
path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF
    
    # Create policy for GitHub Actions
    cat > "$DATA_DIR/github-policy.hcl" << 'EOF'
# GitHub Actions policy
path "kv/data/homeserver/*" {
  capabilities = ["read", "create", "update"]
}

path "kv/metadata/homeserver/*" {
  capabilities = ["read", "list"]
}

# Allow GitHub Actions to update runner token
path "kv/data/homeserver/github" {
  capabilities = ["read", "create", "update", "delete"]
}
EOF
    
    # Upload policies
    vault policy write homeserver-policy "$DATA_DIR/homeserver-policy.hcl"
    vault policy write github-policy "$DATA_DIR/github-policy.hcl"
    
    # Create AppRole for homeserver services
    vault write auth/approle/role/homeserver \
        token_policies="homeserver-policy" \
        token_ttl=1h \
        token_max_ttl=4h \
        bind_secret_id=true
    
    # Create AppRole for GitHub Actions
    vault write auth/approle/role/github-actions \
        token_policies="github-policy" \
        token_ttl=30m \
        token_max_ttl=1h \
        bind_secret_id=true
    
    # Get role IDs and secret IDs
    HOMESERVER_ROLE_ID=$(vault read -field=role_id auth/approle/role/homeserver/role-id)
    HOMESERVER_SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/homeserver/secret-id)
    
    GITHUB_ROLE_ID=$(vault read -field=role_id auth/approle/role/github-actions/role-id)
    GITHUB_SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/github-actions/secret-id)
    
    # Save credentials for Vault Agent
    echo "$HOMESERVER_ROLE_ID" > "$DATA_DIR/agent/role-id"
    echo "$HOMESERVER_SECRET_ID" > "$DATA_DIR/agent/secret-id"
    chmod 600 "$DATA_DIR/agent/role-id" "$DATA_DIR/agent/secret-id"
    
    # Save GitHub Actions credentials
    echo "$GITHUB_ROLE_ID" > "$DATA_DIR/github-role-id.txt"
    echo "$GITHUB_SECRET_ID" > "$DATA_DIR/github-secret-id.txt"
    chmod 600 "$DATA_DIR/github-role-id.txt" "$DATA_DIR/github-secret-id.txt"
    
    log_success "Authentication configured"
    
    echo
    echo "GitHub Actions credentials (add to repository secrets):"
    echo "VAULT_ROLE_ID: $GITHUB_ROLE_ID"
    echo "VAULT_SECRET_ID: $GITHUB_SECRET_ID"
    echo
}

populate_initial_secrets() {
    log_info "Populating initial secrets from .env.example..."
    
    if [[ ! -f "$PROJECT_DIR/.env.example" ]]; then
        log_error ".env.example not found"
        return 1
    fi
    
    # Create secret structure in Vault
    vault kv put kv/homeserver/config \
        TZ="America/New_York" \
        PUID="1000" \
        PGID="1000" \
        DOMAIN="yourdomain.com" \
        NVME_PATH="/mnt/nvme" \
        SSD_PATH="/mnt/ssd" \
        HDD_PATH="/mnt/hdd" \
        RUNNER_NAME="homeserver-runner" \
        PROJECT_PATH="/opt/homeserver" \
        NTP_SERVER="time.cloudflare.com:123"
    
    vault kv put kv/homeserver/cloudflare \
        api_token="your_cloudflare_api_token_here" \
        zone_id="your_cloudflare_zone_id_here" \
        email="your_email@example.com"
    
    vault kv put kv/homeserver/database \
        mysql_root_password="CHANGE_ME_MYSQL_ROOT" \
        redis_password="CHANGE_ME_REDIS_PASSWORD" \
        monitoring_password="CHANGE_ME_MONITORING_PASSWORD" \
        backup_password="CHANGE_ME_BACKUP_PASSWORD"
    
    vault kv put kv/homeserver/services \
        grafana_password="CHANGE_ME_GRAFANA_PASSWORD" \
        qbittorrent_password="CHANGE_ME_QBITTORRENT_PASSWORD" \
        plex_claim="claim-your_plex_claim_token_here"
    
    vault kv put kv/homeserver/authelia \
        jwt_secret="CHANGE_ME_64_CHAR_JWT_SECRET_HERE" \
        session_secret="CHANGE_ME_64_CHAR_SESSION_SECRET_HERE" \
        storage_key="CHANGE_ME_32_CHAR_ENCRYPTION_KEY" \
        admin_password_hash="CHANGE_ME_ADMIN_PASSWORD_HASH" \
        admin_email="admin@yourdomain.com" \
        monitoring_password_hash="CHANGE_ME_MONITORING_PASSWORD_HASH" \
        monitoring_email="monitoring@yourdomain.com" \
        user1_password_hash="CHANGE_ME_USER1_PASSWORD_HASH" \
        user1_email="user@yourdomain.com"
    
    vault kv put kv/homeserver/gaming \
        cs2_server_name="Your CS2 Server" \
        cs2_rcon_password="CHANGE_ME_RCON_PASSWORD" \
        cs2_server_password="" \
        steam_token="your_steam_game_server_token" \
        ts3_admin_password="CHANGE_ME_TS3_PASSWORD"
    
    vault kv put kv/homeserver/notifications \
        discord_webhook="https://discord.com/api/webhooks/your_webhook_here"
    
    vault kv put kv/homeserver/backup \
        encryption_key="CHANGE_ME_32_CHAR_BACKUP_KEY" \
        b2_account_id="your_b2_account_id" \
        b2_account_key="your_b2_account_key" \
        b2_bucket_name="homeserver-backups"
    
    vault kv put kv/homeserver/github \
        repository="yourusername/yourrepo" \
        runner_token="your_github_runner_registration_token"
    
    log_success "Initial secrets populated (with placeholder values)"
    echo
    echo "IMPORTANT: Update all secrets in Vault with real values!"
    echo "Use: vault kv put kv/homeserver/[category] key=value"
    echo
}

start_vault_agent() {
    log_info "Starting Vault Agent..."
    
    # Start Vault Agent
    docker-compose -f docker-compose.yml -f docker-compose.vault.yml up -d vault-agent
    
    log_success "Vault Agent started"
}

show_completion_info() {
    echo
    echo "=========================================="
    echo "Vault Setup Complete!"
    echo "=========================================="
    echo
    echo "Next steps:"
    echo
    echo "1. Add these secrets to GitHub repository:"
    echo "   VAULT_ADDR: http://your-server-ip:8200"
    echo "   VAULT_ROLE_ID: $(cat "$DATA_DIR/github-role-id.txt" 2>/dev/null || echo "See above")"
    echo "   VAULT_SECRET_ID: $(cat "$DATA_DIR/github-secret-id.txt" 2>/dev/null || echo "See above")"
    echo
    echo "2. Update secrets in Vault with real values:"
    echo "   vault kv put kv/homeserver/database mysql_root_password=YOUR_REAL_PASSWORD"
    echo "   # ... update all other secrets"
    echo
    echo "3. Access Vault UI at: http://localhost:8200"
    echo "   Token: $(cat "$DATA_DIR/root-token.txt" 2>/dev/null || echo "See initialization output")"
    echo
    echo "4. Backup unseal keys securely (printed during initialization)"
    echo
    echo "5. Services will automatically get secrets from Vault via Agent"
    echo
    echo "Management commands:"
    echo "  - View secrets: vault kv get kv/homeserver/database"
    echo "  - Update secrets: vault kv put kv/homeserver/database key=newvalue"
    echo "  - Unseal after restart: vault operator unseal <key>"
}

main() {
    log_info "Starting Vault setup..."
    
    check_dependencies
    start_vault_server
    initialize_vault
    setup_secret_engines
    setup_authentication
    populate_initial_secrets
    start_vault_agent
    
    show_completion_info
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi