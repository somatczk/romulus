#!/bin/bash
# Prepare Environment Secrets for GitHub Actions
# Converts .env.template to JSON format and encrypts it

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_TEMPLATE="$REPO_ROOT/.env.template"
SECRETS_DIR="$REPO_ROOT/secrets-encrypted"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}::success:: $1${NC}"
}

warning() {
    echo -e "${YELLOW}::warning::  $1${NC}"
}

error() {
    echo -e "${RED}::error:: $1${NC}"
    exit 1
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Convert .env.template to JSON format and encrypt for GitHub Actions.

OPTIONS:
    -h, --help          Show this help message
    -p, --passphrase    Specify passphrase (will prompt if not provided)
    -o, --output        Output directory (default: secrets-encrypted/)
    -f, --force         Overwrite existing files without confirmation

WORKFLOW:
1. Reads .env.template file
2. Converts environment variables to JSON format
3. Encrypts JSON file using GPG
4. Creates encrypted secrets suitable for GitHub Actions

GITHUB SECRETS REQUIRED:
- ENV_SECRETS_PASSPHRASE: The passphrase to decrypt the environment JSON

The encrypted file will contain ALL environment variables from .env.template
in the correct JSON format for GitHub Actions environment loading.
EOF
}

convert_env_to_json() {
    local env_file="$1"
    local json_file="$2"
    
    log "Converting $env_file to JSON format..."
    
    # Create JSON object from environment variables
    echo "{" > "$json_file"
    
    local first_entry=true
    while IFS= read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// /}" ]]; then
            continue
        fi
        
        # Extract key=value pairs
        if [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]// /}"
            local value="${BASH_REMATCH[2]}"
            
            # Remove quotes from value if present
            value=$(echo "$value" | sed 's/^["'\'']//' | sed 's/["'\'']$//')
            
            # Add comma for all entries except the first
            if [[ "$first_entry" == false ]]; then
                echo "," >> "$json_file"
            fi
            first_entry=false
            
            # Escape JSON special characters in value
            value=$(echo "$value" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/$//')
            
            # Write JSON key-value pair
            echo -n "  \"$key\": \"$value\"" >> "$json_file"
        fi
    done < "$env_file"
    
    echo "" >> "$json_file"
    echo "}" >> "$json_file"
    
    success "Environment variables converted to JSON"
}

validate_json() {
    local json_file="$1"
    
    if command -v jq >/dev/null 2>&1; then
        if jq empty "$json_file" >/dev/null 2>&1; then
            success "JSON validation passed"
            local count
            count=$(jq 'keys | length' "$json_file")
            log "Converted $count environment variables"
        else
            error "Invalid JSON generated. Please check the conversion."
        fi
    else
        warning "jq not available for JSON validation. Proceeding..."
    fi
}

# Parse command line arguments
PASSPHRASE=""
OUTPUT_DIR="$SECRETS_DIR"
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -p|--passphrase)
            PASSPHRASE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            error "Unexpected argument: $1"
            ;;
    esac
done

# Validate inputs
if [[ ! -f "$ENV_TEMPLATE" ]]; then
    error ".env.template file not found: $ENV_TEMPLATE"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Define output files
JSON_FILE="$OUTPUT_DIR/homeserver-env-secrets.json"
ENCRYPTED_FILE="$OUTPUT_DIR/homeserver-env-secrets.json.gpg"

# Check for existing files
if [[ -f "$ENCRYPTED_FILE" && "$FORCE" == false ]]; then
    warning "Encrypted file already exists: $ENCRYPTED_FILE"
    read -p "Overwrite? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Get passphrase if not provided
if [[ -z "$PASSPHRASE" ]]; then
    log "Enter passphrase for encryption (will be hidden):"
    read -s PASSPHRASE
    echo
    if [[ -z "$PASSPHRASE" ]]; then
        error "Passphrase cannot be empty"
    fi
    
    log "Confirm passphrase:"
    read -s PASSPHRASE_CONFIRM
    echo
    
    if [[ "$PASSPHRASE" != "$PASSPHRASE_CONFIRM" ]]; then
        error "Passphrases do not match"
    fi
fi

# Convert .env.template to JSON
convert_env_to_json "$ENV_TEMPLATE" "$JSON_FILE"

# Validate JSON
validate_json "$JSON_FILE"

# Validate JSON structure (without showing content)
log "JSON file created and validated"

# Get file size
JSON_SIZE=$(stat -f%z "$JSON_FILE" 2>/dev/null || stat -c%s "$JSON_FILE" 2>/dev/null)
log "JSON file size: $JSON_SIZE bytes"

if [[ $JSON_SIZE -lt 49152 ]]; then  # 48KB
    warning "JSON file is smaller than 48KB. You could use individual GitHub Secrets instead."
    warning "This approach is still useful for managing all environment variables in one place."
fi

# Encrypt the JSON file
log "Encrypting environment secrets..."
if GNUPGHOME=/tmp/gpg-temp gpg --quiet --batch --yes --symmetric --cipher-algo AES256 \
   --passphrase "$PASSPHRASE" --output "$ENCRYPTED_FILE" "$JSON_FILE"; then
    success "Environment secrets encrypted successfully!"
else
    error "Encryption failed"
fi

# Clean up unencrypted JSON
rm -f "$JSON_FILE"
success "Temporary JSON file removed"

# Get encrypted file size
ENCRYPTED_SIZE=$(stat -f%z "$ENCRYPTED_FILE" 2>/dev/null || stat -c%s "$ENCRYPTED_FILE" 2>/dev/null)

# Display next steps
cat << EOF

${GREEN}Environment Secrets Encryption Complete!${NC}

${BLUE}Files Created:${NC}
- Encrypted: $ENCRYPTED_FILE ($ENCRYPTED_SIZE bytes)

${BLUE}Next Steps:${NC}

1. ${YELLOW}Add encrypted file to git:${NC}
   git add $ENCRYPTED_FILE
   git commit -m "Add encrypted environment secrets"

2. ${YELLOW}Create GitHub Secret for passphrase:${NC}
   - Secret name: ${GREEN}ENV_SECRETS_PASSPHRASE${NC}
   - Secret value: [the passphrase you just used]

3. ${YELLOW}Update your GitHub Actions workflow:${NC}
   Add this step before other deployment steps:
   
   - name: Decrypt Environment Secrets
     run: ./scripts/decrypt-large-secrets.sh homeserver-env-secrets.json
     env:
       LARGE_SECRET_PASSPHRASE_HOMESERVER_ENV_SECRETS_JSON: \${{ secrets.ENV_SECRETS_PASSPHRASE }}
   
   - name: Load Environment Variables
     run: |
       # Load all environment variables from decrypted JSON
       echo "Loading environment variables from JSON..."
       jq -r 'to_entries[] | "\(.key)=\(.value)"' \$HOME/secrets/homeserver-env-secrets.json >> \$GITHUB_ENV

4. ${YELLOW}Remove individual secrets:${NC}
   You can now remove the 46+ individual GitHub Secrets since they'll be loaded from the JSON file.

${RED}Security Reminders:${NC}
- Store only the passphrase as a GitHub Secret
- Never commit the unencrypted .env or JSON files
- The workflow will load all variables automatically
- Update the encrypted file when .env.template changes

${BLUE}File Contents:${NC}
- All environment variables from .env.template
- JSON format compatible with GitHub Actions
- AES256 encryption

EOF