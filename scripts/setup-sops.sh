#!/bin/bash

# SOPS + age Secret Management Setup Script
# 
# Purpose: Initialize encrypted secret management using SOPS and age
# Usage: ./scripts/setup-sops.sh
# 
# This script sets up:
# 1. age key generation for encryption
# 2. SOPS configuration
# 3. Encrypted .env file creation
# 4. GitHub Actions integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="$PROJECT_DIR/secrets"

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
    
    if ! command -v age &> /dev/null; then
        log_error "age is not installed. Install with: brew install age (macOS) or apt install age (Ubuntu)"
        exit 1
    fi
    
    if ! command -v sops &> /dev/null; then
        log_error "sops is not installed. Install with: brew install sops (macOS) or download from GitHub releases"
        exit 1
    fi
    
    log_success "Dependencies installed"
}

setup_age_key() {
    log_info "Setting up age encryption key..."
    
    mkdir -p "$SECRETS_DIR"
    
    if [[ -f "$SECRETS_DIR/age-key.txt" ]]; then
        log_info "Age key already exists"
        return 0
    fi
    
    # Generate age key pair
    age-keygen -o "$SECRETS_DIR/age-key.txt"
    chmod 600 "$SECRETS_DIR/age-key.txt"
    
    # Extract public key
    PUBLIC_KEY=$(grep "# public key:" "$SECRETS_DIR/age-key.txt" | cut -d' ' -f4)
    echo "$PUBLIC_KEY" > "$SECRETS_DIR/age-public-key.txt"
    
    log_success "Age key generated: $PUBLIC_KEY"
    echo
    echo "IMPORTANT: Add this to GitHub Secrets as 'AGE_SECRET_KEY':"
    cat "$SECRETS_DIR/age-key.txt"
    echo
}

setup_sops_config() {
    log_info "Setting up SOPS configuration..."
    
    if [[ ! -f "$SECRETS_DIR/age-public-key.txt" ]]; then
        log_error "Public key file not found. Run setup_age_key first."
        exit 1
    fi
    
    PUBLIC_KEY=$(cat "$SECRETS_DIR/age-public-key.txt")
    
    cat > "$SECRETS_DIR/.sops.yaml" << EOF
creation_rules:
  - path_regex: \.env\.encrypted$
    age: $PUBLIC_KEY
  - path_regex: secrets\.ya?ml$
    age: $PUBLIC_KEY
EOF
    
    log_success "SOPS configuration created"
}

create_encrypted_env() {
    log_info "Creating encrypted .env file..."
    
    if [[ ! -f "$PROJECT_DIR/.env.example" ]]; then
        log_error ".env.example not found"
        exit 1
    fi
    
    # Copy .env.example as base template
    cp "$PROJECT_DIR/.env.example" "$SECRETS_DIR/.env.template"
    
    # Create initial encrypted version
    cd "$SECRETS_DIR"
    sops --encrypt --input-type dotenv --output-type dotenv .env.template > .env.encrypted
    
    # Clean up template
    rm .env.template
    
    log_success "Encrypted .env file created at $SECRETS_DIR/.env.encrypted"
    echo
    echo "To edit secrets: cd secrets && sops .env.encrypted"
}

update_gitignore() {
    log_info "Updating .gitignore..."
    
    cat >> "$PROJECT_DIR/.gitignore" << EOF

# SOPS secret management
secrets/age-key.txt
secrets/.env.decrypted
secrets/*.key
EOF
    
    log_success "Updated .gitignore"
}

create_github_action() {
    log_info "Creating GitHub Action for secret deployment..."
    
    mkdir -p "$PROJECT_DIR/.github/workflows"
    
    cat > "$PROJECT_DIR/.github/workflows/deploy-secrets.yml" << 'EOF'
name: Deploy Secrets

on:
  workflow_call:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  deploy-secrets:
    name: Deploy Secrets to Server
    runs-on: self-hosted
    timeout-minutes: 10
    permissions:
      contents: read
    
    steps:
    - name: Checkout Repository
      uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      with:
        persist-credentials: false
    
    - name: Install SOPS and age
      run: |
        if ! command -v sops &> /dev/null; then
          echo "Installing SOPS..."
          curl -LO https://github.com/getsops/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64
          sudo mv sops-v3.8.1.linux.amd64 /usr/local/bin/sops
          sudo chmod +x /usr/local/bin/sops
        fi
        
        if ! command -v age &> /dev/null; then
          echo "Installing age..."
          curl -LO https://github.com/FiloSottile/age/releases/download/v1.1.1/age-v1.1.1-linux-amd64.tar.gz
          tar xf age-v1.1.1-linux-amd64.tar.gz
          sudo mv age/age* /usr/local/bin/
          rm -rf age*
        fi
    
    - name: Decrypt and Deploy Secrets
      run: |
        echo "Decrypting secrets..."
        
        # Create age key file from secret
        mkdir -p ~/.config/sops/age
        echo "${{ secrets.AGE_SECRET_KEY }}" > ~/.config/sops/age/keys.txt
        chmod 600 ~/.config/sops/age/keys.txt
        
        # Decrypt .env file
        cd secrets
        sops --decrypt --input-type dotenv --output-type dotenv .env.encrypted > .env.decrypted
        
        # Deploy to project root
        mv .env.decrypted ../.env
        chmod 600 ../.env
        
        echo "Secrets deployed successfully"
    
    - name: Verify Deployment
      run: |
        if [[ ! -f .env ]]; then
          echo "ERROR: .env file not found after deployment"
          exit 1
        fi
        
        # Check that key variables are present (without revealing values)
        required_vars=(
          "DOMAIN"
          "MYSQL_ROOT_PASSWORD"
          "REDIS_PASSWORD"
        )
        
        for var in "${required_vars[@]}"; do
          if ! grep -q "^${var}=" .env; then
            echo "ERROR: Required variable $var not found in .env"
            exit 1
          fi
        done
        
        echo "Secret verification passed"
EOF
    
    log_success "GitHub Action created"
}

create_helper_scripts() {
    log_info "Creating helper scripts..."
    
    cat > "$SECRETS_DIR/edit-secrets.sh" << 'EOF'
#!/bin/bash
# Edit encrypted secrets using SOPS
cd "$(dirname "${BASH_SOURCE[0]}")"
sops .env.encrypted
EOF
    
    cat > "$SECRETS_DIR/decrypt-local.sh" << 'EOF'
#!/bin/bash
# Decrypt secrets for local development
cd "$(dirname "${BASH_SOURCE[0]}")"
sops --decrypt --input-type dotenv --output-type dotenv .env.encrypted > ../.env
chmod 600 ../.env
echo "Secrets decrypted to ../.env"
EOF
    
    chmod +x "$SECRETS_DIR/edit-secrets.sh"
    chmod +x "$SECRETS_DIR/decrypt-local.sh"
    
    log_success "Helper scripts created"
}

show_usage_instructions() {
    echo
    echo "=========================================="
    echo "SOPS + age Setup Complete!"
    echo "=========================================="
    echo
    echo "Next steps:"
    echo
    echo "1. Add AGE_SECRET_KEY to GitHub repository secrets:"
    echo "   - Go to repository Settings > Secrets and variables > Actions"
    echo "   - Add new secret: AGE_SECRET_KEY"
    echo "   - Value: contents of secrets/age-key.txt"
    echo
    echo "2. Edit your encrypted secrets:"
    echo "   cd secrets && ./edit-secrets.sh"
    echo
    echo "3. For local development:"
    echo "   cd secrets && ./decrypt-local.sh"
    echo
    echo "4. Commit encrypted files to git:"
    echo "   git add secrets/.env.encrypted secrets/.sops.yaml"
    echo "   git add .github/workflows/deploy-secrets.yml"
    echo "   git commit -m 'Add encrypted secret management'"
    echo
    echo "5. Update main deployment workflow to call deploy-secrets job"
    echo
    echo "Security notes:"
    echo "- Never commit age-key.txt or decrypted files"
    echo "- Rotate age keys periodically"
    echo "- Use different keys for different environments"
}

main() {
    log_info "Starting SOPS + age secret management setup..."
    
    check_dependencies
    setup_age_key
    setup_sops_config
    create_encrypted_env
    update_gitignore
    create_github_action
    create_helper_scripts
    
    show_usage_instructions
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi