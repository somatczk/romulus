#!/bin/bash
set -euo pipefail

# BTRFS snapshot management
# Usage: btrfs-snapshot.sh <ssd|hdd>
# SSD: hourly snapshots, keep 24
# HDD: daily snapshots, keep 7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../stacks/.env"

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo)."
    exit 1
fi

DRIVE="${1:-}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [ -z "${DRIVE}" ]; then
    echo "Usage: $0 <ssd|hdd>"
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${DRIVE}] $1"
}

case "${DRIVE}" in
    ssd)
        SUBVOLUME="/media/SSD-Storage"
        SNAPSHOT_DIR="/media/SSD-Storage/.snapshots"
        KEEP=24
        ;;
    hdd)
        SUBVOLUME="/media/HDD-Storage"
        SNAPSHOT_DIR="/media/HDD-Storage/.snapshots"
        KEEP=7
        ;;
    *)
        echo "Error: Invalid drive '${DRIVE}'. Use 'ssd' or 'hdd'."
        exit 1
        ;;
esac

mkdir -p "${SNAPSHOT_DIR}"

# Create readonly snapshot
SNAPSHOT_NAME="snapshot_${TIMESTAMP}"
log "Creating readonly snapshot: ${SNAPSHOT_DIR}/${SNAPSHOT_NAME}"
btrfs subvolume snapshot -r "${SUBVOLUME}" "${SNAPSHOT_DIR}/${SNAPSHOT_NAME}"
log "Snapshot created successfully"

# Cleanup old snapshots - keep only the most recent $KEEP
SNAPSHOT_COUNT=$(find "${SNAPSHOT_DIR}" -maxdepth 1 -name "snapshot_*" -type d | wc -l)
if [ "${SNAPSHOT_COUNT}" -gt "${KEEP}" ]; then
    DELETE_COUNT=$((SNAPSHOT_COUNT - KEEP))
    log "Cleaning up ${DELETE_COUNT} old snapshot(s) (keeping ${KEEP})..."
    find "${SNAPSHOT_DIR}" -maxdepth 1 -name "snapshot_*" -type d | sort | head -n "${DELETE_COUNT}" | while read -r old_snapshot; do
        log "Deleting: ${old_snapshot}"
        btrfs subvolume delete "${old_snapshot}"
    done
    log "Cleanup complete"
else
    log "No cleanup needed (${SNAPSHOT_COUNT}/${KEEP} snapshots)"
fi
