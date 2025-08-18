#!/bin/bash
# GPG Decryption Script for GitHub Actions
# Decrypts large secrets during workflow execution

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENCRYPTED_DIR="$SCRIPT_DIR/../secrets-encrypted"
DECRYPTED_DIR="${HOME}/secrets"

# Colors for output (GitHub Actions compatible)
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}::notice::${NC}$1"
}

success() {
    echo -e "${GREEN}::notice::$1${NC}"
}

warning() {
    echo -e "${YELLOW}::warning:: $1${NC}"
}

error() {
    echo -e "${RED}::error::$1${NC}"
    exit 1
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <secret-filename>

Decrypt GPG-encrypted secrets in GitHub Actions workflows.

OPTIONS:
    -h, --help          Show this help message
    -a, --all           Decrypt all encrypted files in secrets-encrypted/
    -o, --output        Output directory (default: \$HOME/secrets)
    -v, --verbose       Verbose output for debugging

EXAMPLES:
    $0 ssl-certificates.json        # Decrypts ssl-certificates.json.gpg
    $0 --all                       # Decrypts all .gpg files
    $0 -o /tmp/secrets config.env  # Custom output directory

ENVIRONMENT VARIABLES:
    Required passphrase environment variables:
    - LARGE_SECRET_PASSPHRASE_<FILENAME>  # Specific file passphrase
    - LARGE_SECRET_PASSPHRASE             # Fallback global passphrase

WORKFLOW INTEGRATION:
    - name: Decrypt Large Secrets
      run: ./scripts/decrypt-large-secrets.sh ssl-certificates.json
      env:
        LARGE_SECRET_PASSPHRASE_SSL_CERTIFICATES_JSON: \${{ secrets.LARGE_SECRET_PASSPHRASE_SSL_CERTIFICATES_JSON }}
EOF
}

get_passphrase_var_name() {
    local filename="$1"
    # Convert filename to uppercase, replace dots and dashes with underscores
    echo "LARGE_SECRET_PASSPHRASE_$(echo "$filename" | tr '[:lower:].-' '[:upper:]_')"
}

decrypt_file() {
    local secret_filename="$1"
    local encrypted_file="$ENCRYPTED_DIR/${secret_filename}.gpg"
    local output_file="$DECRYPTED_DIR/$secret_filename"
    
    if [[ ! -f "$encrypted_file" ]]; then
        error "Encrypted file not found: $encrypted_file"
    fi
    
    # Try to get specific passphrase first, then fallback to global
    local passphrase_var_name
    passphrase_var_name=$(get_passphrase_var_name "$secret_filename")
    local passphrase="${!passphrase_var_name:-${LARGE_SECRET_PASSPHRASE:-}}"
    
    if [[ -z "$passphrase" ]]; then
        error "No passphrase found. Set $passphrase_var_name or LARGE_SECRET_PASSPHRASE environment variable."
    fi
    
    log "Decrypting: $secret_filename"
    
    # Create output directory
    mkdir -p "$(dirname "$output_file")"
    
    # Decrypt the file
    if gpg --quiet --batch --yes --decrypt \
           --passphrase "$passphrase" \
           --output "$output_file" \
           "$encrypted_file" 2>/dev/null; then
        success "Decrypted: $secret_filename → $output_file"
        
        # Set secure permissions
        chmod 600 "$output_file"
        
        # Verify file was created and has content
        if [[ -s "$output_file" ]]; then
            local file_size
            file_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null)
            log "File size: $file_size bytes"
        else
            warning "Decrypted file appears to be empty"
        fi
    else
        error "Failed to decrypt $secret_filename. Check passphrase and file integrity."
    fi
}

# Parse command line arguments
DECRYPT_ALL=false
OUTPUT_DIR="$DECRYPTED_DIR"
VERBOSE=false
SECRET_FILENAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -a|--all)
            DECRYPT_ALL=true
            shift
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            DECRYPTED_DIR="$OUTPUT_DIR"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            set -x
            shift
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            if [[ -z "$SECRET_FILENAME" ]]; then
                SECRET_FILENAME="$1"
            else
                error "Multiple filenames specified. Use --all to decrypt all files."
            fi
            shift
            ;;
    esac
done

# Main execution
log "Starting secret decryption..."
log "Encrypted files directory: $ENCRYPTED_DIR"
log "Output directory: $DECRYPTED_DIR"

if [[ "$DECRYPT_ALL" == "true" ]]; then
    # Decrypt all .gpg files
    if [[ ! -d "$ENCRYPTED_DIR" ]]; then
        error "Encrypted directory not found: $ENCRYPTED_DIR"
    fi
    
    local gpg_files
    gpg_files=$(find "$ENCRYPTED_DIR" -name "*.gpg" -type f 2>/dev/null || true)
    
    if [[ -z "$gpg_files" ]]; then
        warning "No encrypted files found in $ENCRYPTED_DIR"
        exit 0
    fi
    
    log "Found encrypted files:"
    echo "$gpg_files" | while read -r encrypted_file; do
        if [[ -n "$encrypted_file" ]]; then
            local basename
            basename=$(basename "$encrypted_file" .gpg)
            echo "  - $basename"
        fi
    done
    
    echo "$gpg_files" | while read -r encrypted_file; do
        if [[ -n "$encrypted_file" ]]; then
            local basename
            basename=$(basename "$encrypted_file" .gpg)
            decrypt_file "$basename"
        fi
    done
    
    success "All secrets decrypted successfully!"
    
elif [[ -n "$SECRET_FILENAME" ]]; then
    # Decrypt specific file
    decrypt_file "$SECRET_FILENAME"
    success "Secret decrypted successfully!"
    
else
    error "No filename specified and --all not used. Use -h for help."
fi

# Summary
log "Decryption complete. Files available in: $DECRYPTED_DIR"

# Security reminder
warning "Remember: Decrypted files contain sensitive data. Ensure they're not logged or exposed."

# List decrypted files (without content)
if [[ -d "$DECRYPTED_DIR" ]]; then
    log "Decrypted files:"
    find "$DECRYPTED_DIR" -type f -exec basename {} \; 2>/dev/null | sort | while read -r file; do
        echo "  - $file"
    done
fi