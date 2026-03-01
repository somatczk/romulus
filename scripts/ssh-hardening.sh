#!/usr/bin/env bash
# =============================================================================
# ZimaOS - SSH Hardening Script
# =============================================================================
# Hardens the SSH daemon configuration. Creates a backup of the current config
# before making changes.
#
# Usage: sudo bash ssh-hardening.sh
#
# IMPORTANT: After running this script, open a NEW terminal and test SSH access
#            BEFORE closing your current session!
# =============================================================================
set -euo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_PATH="${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (sudo)."
    exit 1
fi

if [[ ! -f "$SSHD_CONFIG" ]]; then
    log_error "SSHD config not found at ${SSHD_CONFIG}."
    exit 1
fi

# =============================================================================
# 1. Backup current configuration
# =============================================================================
log_info "Backing up current sshd_config to ${BACKUP_PATH}..."
cp "$SSHD_CONFIG" "$BACKUP_PATH"
log_info "Backup created."

# =============================================================================
# 2. Apply hardened settings
# =============================================================================
log_info "Applying hardened SSH settings..."

# Helper: set or replace a directive in sshd_config
set_sshd_option() {
    local key="$1"
    local value="$2"
    if grep -qE "^\s*#?\s*${key}\s+" "$SSHD_CONFIG"; then
        # Replace existing (commented or uncommented) line
        sed -i "s|^\s*#\?\s*${key}\s\+.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        # Append if not found
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
    log_info "  ${key} = ${value}"
}

set_sshd_option "PasswordAuthentication" "no"
set_sshd_option "PermitRootLogin" "no"
set_sshd_option "Port" "2222"
set_sshd_option "AllowUsers" "somatczk"
set_sshd_option "MaxAuthTries" "3"
set_sshd_option "LoginGraceTime" "30"
set_sshd_option "X11Forwarding" "no"

# =============================================================================
# 3. Validate configuration
# =============================================================================
log_info "Validating sshd configuration..."
if sshd -t -f "$SSHD_CONFIG"; then
    log_info "Configuration is valid."
else
    log_error "Configuration validation failed! Restoring backup..."
    cp "$BACKUP_PATH" "$SSHD_CONFIG"
    log_error "Backup restored. Please check your settings manually."
    exit 1
fi

# =============================================================================
# 4. Restart SSHD
# =============================================================================
log_info "Restarting sshd..."
if systemctl restart sshd; then
    log_info "sshd restarted successfully."
elif systemctl restart ssh; then
    log_info "ssh restarted successfully (Debian/Ubuntu service name)."
else
    log_error "Failed to restart SSH daemon. Please restart manually."
    exit 1
fi

# =============================================================================
# Warning
# =============================================================================
echo ""
echo -e "${RED}=============================================================================${NC}"
echo -e "${RED} WARNING: DO NOT close this terminal session!${NC}"
echo -e "${RED}=============================================================================${NC}"
echo ""
echo "  SSH is now configured on port 2222 with key-based auth only."
echo "  Only user 'somatczk' is allowed to connect."
echo ""
echo "  Before closing this session, open a NEW terminal and verify access:"
echo ""
echo "    ssh -p 2222 somatczk@<server-ip>"
echo ""
echo "  If you cannot connect, restore the backup:"
echo ""
echo "    sudo cp ${BACKUP_PATH} ${SSHD_CONFIG}"
echo "    sudo systemctl restart sshd"
echo ""
echo -e "${GREEN}  Backup location: ${BACKUP_PATH}${NC}"
echo ""
