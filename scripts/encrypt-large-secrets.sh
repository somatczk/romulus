#!/bin/bash
# GPG Encryption Script for Large Secrets
# Encrypts files that are too large for GitHub Secrets (>48KB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$SCRIPT_DIR/../secrets"
ENCRYPTED_DIR="$SCRIPT_DIR/../secrets-encrypted"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <secret-file>

Encrypt large secret files using GPG for GitHub Actions deployment.

OPTIONS:
    -h, --help          Show this help message
    -p, --passphrase    Specify passphrase (will prompt if not provided)
    -o, --output        Output directory (default: secrets-encrypted/)
    -c, --cipher        Cipher algorithm (default: AES256)

EXAMPLES:
    $0 ssl-certificates.json
    $0 -p mypassphrase config.env
    $0 --output ./encrypted/ large-config.yaml

SUPPORTED SECRET TYPES:
    - SSL certificates and private keys
    - Large environment files
    - Configuration files with sensitive data
    - Service account keys
    - Database dumps or backups

The encrypted file will be saved as <filename>.gpg and should be:
    1. Committed to the repository
    2. Decrypted in GitHub Actions using the passphrase secret
EOF
}

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}::success:: $1${NC}"
}

warning() {
    echo -e "${YELLOW}::warning:: $1${NC}"
}

error() {
    echo -e "${RED}::error::$1${NC}"
    exit 1
}

# Parse command line arguments
PASSPHRASE=""
OUTPUT_DIR="$ENCRYPTED_DIR"
CIPHER="AES256"
SECRET_FILE=""

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
        -c|--cipher)
            CIPHER="$2"
            shift 2
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            if [[ -z "$SECRET_FILE" ]]; then
                SECRET_FILE="$1"
            else
                error "Multiple files specified. Please encrypt one file at a time."
            fi
            shift
            ;;
    esac
done

# Validate inputs
if [[ -z "$SECRET_FILE" ]]; then
    error "No secret file specified. Use -h for help."
fi

if [[ ! -f "$SECRET_FILE" ]]; then
    error "Secret file not found: $SECRET_FILE"
fi

# Check file size
FILE_SIZE=$(stat -f%z "$SECRET_FILE" 2>/dev/null || stat -c%s "$SECRET_FILE" 2>/dev/null)
if [[ $FILE_SIZE -lt 49152 ]]; then  # 48KB
    warning "File is smaller than 48KB ($FILE_SIZE bytes). Consider using regular GitHub Secrets instead."
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

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

# Generate output filename
BASENAME=$(basename "$SECRET_FILE")
OUTPUT_FILE="$OUTPUT_DIR/${BASENAME}.gpg"

log "Encrypting $SECRET_FILE..."
log "Output: $OUTPUT_FILE"
log "Cipher: $CIPHER"

# Encrypt the file
if GNUPGHOME=/tmp/gpg-temp gpg --quiet --batch --yes --symmetric --cipher-algo "$CIPHER" \
   --passphrase "$PASSPHRASE" --output "$OUTPUT_FILE" "$SECRET_FILE"; then
    success "File encrypted successfully!"
else
    error "Encryption failed"
fi

# Display next steps
cat << EOF

${GREEN}Encryption Complete!${NC}

${BLUE}Next Steps:${NC}
1. Add the encrypted file to git:
   ${YELLOW}git add $OUTPUT_FILE${NC}
   ${YELLOW}git commit -m "Add encrypted secret: $BASENAME"${NC}

2. Create GitHub Secret for the passphrase:
   - Secret name: ${YELLOW}LARGE_SECRET_PASSPHRASE_$(echo "$BASENAME" | tr '[:lower:].' '[:upper:]_')${NC}
   - Secret value: [the passphrase you just used]

3. Update your GitHub Actions workflow to decrypt:
   ${YELLOW}./scripts/decrypt-large-secrets.sh $BASENAME${NC}

${BLUE}File Details:${NC}
- Original: $SECRET_FILE ($FILE_SIZE bytes)
- Encrypted: $OUTPUT_FILE ($(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null) bytes)
- Cipher: $CIPHER

${RED}Security Reminders:${NC}
- Store the passphrase securely in GitHub Secrets
- Never commit the unencrypted file
- Ensure logs don't print decrypted content
- Consider file permissions in workflows

EOF