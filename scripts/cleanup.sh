#!/usr/bin/env bash
# =============================================================================
# ZimaOS - Phase 0 Cleanup Script
# =============================================================================
# Removes legacy directories and containers from the previous CasaOS setup.
# Run this BEFORE the main setup to start fresh.
#
# Usage: sudo bash cleanup.sh
# =============================================================================
set -euo pipefail

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

# =============================================================================
# 1. Remove legacy directories
# =============================================================================
LEGACY_DIRS=(
    "/media/SSD-Storage/openwebui"
    "/media/SSD-Storage/modelThins"
)

for dir in "${LEGACY_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        log_info "Removing legacy directory: ${dir}"
        rm -rf "$dir"
        log_info "Removed: ${dir}"
    else
        log_warn "Directory not found (already removed?): ${dir}"
    fi
done

# =============================================================================
# 2. Stop old CasaOS containers
# =============================================================================
log_info "Stopping old CasaOS qBittorrent container (if running)..."

# Try common CasaOS container names for qBittorrent
QBIT_CONTAINERS=("qbittorrent" "casaos-qbittorrent" "qbittorrent-nox")

for container in "${QBIT_CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        log_info "Stopping and removing container: ${container}"
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
        log_info "Removed container: ${container}"
    fi
done

# Also check for any CasaOS-managed containers
if docker ps -a --format '{{.Names}}' | grep -qi "casaos"; then
    log_warn "Found other CasaOS containers. Consider removing them manually:"
    docker ps -a --format '{{.Names}}' | grep -i "casaos"
fi

# =============================================================================
# 3. Add current user to docker group
# =============================================================================
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"

if [[ -n "$REAL_USER" ]]; then
    if groups "$REAL_USER" | grep -q '\bdocker\b'; then
        log_warn "User '${REAL_USER}' is already in the docker group."
    else
        log_info "Adding user '${REAL_USER}' to the docker group..."
        usermod -aG docker "$REAL_USER"
        log_info "User '${REAL_USER}' added to docker group."
        log_warn "Log out and back in for group changes to take effect."
    fi
else
    log_warn "Could not determine the real user. Please run manually:"
    echo "    sudo usermod -aG docker <your-username>"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}=============================================================================${NC}"
echo -e "${GREEN} Phase 0 cleanup complete.${NC}"
echo -e "${GREEN}=============================================================================${NC}"
echo ""
echo "  You can now proceed with:"
echo "    1. sudo bash scripts/setup.sh"
echo "    2. sudo bash scripts/firewall.sh"
echo "    3. sudo bash scripts/ssh-hardening.sh"
echo ""
