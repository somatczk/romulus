#!/bin/bash
set -euo pipefail

# BTRFS maintenance: scrub and balance
# Usage: btrfs-maintenance.sh <scrub|balance>
# Scrub: weekly (Sunday), Balance: monthly (1st)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../.env"

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo)."
    exit 1
fi

ACTION="${1:-}"
NTFY_URL="https://notify.${DOMAIN}/maintenance"
SSD="/media/SSD-Storage"
HDD="/media/HDD-Storage"

if [ -z "${ACTION}" ]; then
    echo "Usage: $0 <scrub|balance>"
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${ACTION}] $1"
}

notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    curl -sf -H "Title: ${title}" -H "Priority: ${priority}" -d "${message}" "${NTFY_URL}" || true
}

check_scrub_status() {
    local mount="$1"
    local label="$2"
    local status
    status=$(btrfs scrub status "${mount}" 2>&1)

    if echo "${status}" | grep -q "no errors found"; then
        log "${label}: Scrub completed with no errors"
    else
        local error_line
        error_line=$(echo "${status}" | grep -i "error" || echo "Check manually")
        log "WARNING: ${label} scrub reported issues: ${error_line}"
        notify "BTRFS Scrub ALERT - ${label}" "Scrub errors detected on ${label}: ${error_line}" "high"
    fi
}

case "${ACTION}" in
    scrub)
        log "Starting BTRFS scrub on SSD..."
        btrfs scrub start -B "${SSD}" 2>&1
        check_scrub_status "${SSD}" "SSD"

        log "Starting BTRFS scrub on HDD..."
        btrfs scrub start -B "${HDD}" 2>&1
        check_scrub_status "${HDD}" "HDD"

        notify "BTRFS Scrub Complete" "Weekly scrub finished on SSD and HDD" "low"
        log "Scrub maintenance complete"
        ;;
    balance)
        log "Starting BTRFS balance on SSD..."
        btrfs balance start -dusage=50 -musage=50 "${SSD}" 2>&1
        log "SSD balance complete"

        log "Starting BTRFS balance on HDD..."
        btrfs balance start -dusage=50 -musage=50 "${HDD}" 2>&1
        log "HDD balance complete"

        notify "BTRFS Balance Complete" "Monthly balance finished on SSD and HDD" "low"
        log "Balance maintenance complete"
        ;;
    *)
        echo "Error: Invalid action '${ACTION}'. Use 'scrub' or 'balance'."
        exit 1
        ;;
esac
