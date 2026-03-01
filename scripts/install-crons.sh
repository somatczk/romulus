#!/bin/bash
set -euo pipefail

# Install all crontab entries for homelab automation
# Run once to set up the schedule

SCRIPTS_DIR="/DATA/stacks/stacks/scripts"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Define cron entries
CRON_ENTRIES=(
    "@reboot mkdir -p /var/log/homelab && ${SCRIPTS_DIR}/firewall.sh"
    "0 3 * * * ${SCRIPTS_DIR}/backup.sh >> /var/log/homelab/backup.log 2>&1"
    "0 * * * * ${SCRIPTS_DIR}/btrfs-snapshot.sh ssd >> /var/log/homelab/snapshot-ssd.log 2>&1"
    "0 4 * * * ${SCRIPTS_DIR}/btrfs-snapshot.sh hdd >> /var/log/homelab/snapshot-hdd.log 2>&1"
    "0 5 * * 0 ${SCRIPTS_DIR}/btrfs-maintenance.sh scrub >> /var/log/homelab/maintenance.log 2>&1"
    "0 5 1 * * ${SCRIPTS_DIR}/btrfs-maintenance.sh balance >> /var/log/homelab/maintenance.log 2>&1"
    "0 6 1 * * ${SCRIPTS_DIR}/restore-test.sh >> /var/log/homelab/restore-test.log 2>&1"
    "0 5 * * 3 /bin/bash -c 'export PATH=\$PATH:/DATA/bin && export XDG_CACHE_HOME=/DATA/.cache && source /DATA/stacks/stacks/.env && export RESTIC_REPOSITORY=/media/HDD-Storage/backups/restic-repo && export RESTIC_PASSWORD && restic check' >> /var/log/homelab/restic-check.log 2>&1"
    "0 3 * * 0 docker system prune -f --volumes --filter 'until=168h' >> /var/log/homelab/docker-cleanup.log 2>&1"
)

# Create log directory
mkdir -p /var/log/homelab

# Backup existing crontab
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
if [ -n "${EXISTING_CRON}" ]; then
    log "Backing up existing crontab..."
    echo "${EXISTING_CRON}" > "/tmp/crontab_backup_$(date +%Y%m%d_%H%M%S)"
fi

# Build new crontab: keep existing entries, add ours with markers
MARKER_START="# --- HOMELAB MANAGED START ---"
MARKER_END="# --- HOMELAB MANAGED END ---"

# Remove any existing managed block
CLEAN_CRON=$(echo "${EXISTING_CRON}" | sed "/${MARKER_START}/,/${MARKER_END}/d")

# Build new crontab
{
    if [ -n "${CLEAN_CRON}" ]; then
        echo "${CLEAN_CRON}"
        echo ""
    fi
    echo "${MARKER_START}"
    for entry in "${CRON_ENTRIES[@]}"; do
        echo "${entry}"
    done
    echo "${MARKER_END}"
} | crontab -

log "Crontab installed successfully. Current entries:"
crontab -l
log ""
log "Schedule summary:"
log "  @reboot     - Firewall rules"
log "  3:00 daily  - Full backup (DB dumps + restic)"
log "  Hourly      - BTRFS SSD snapshots"
log "  4:00 daily  - BTRFS HDD snapshots"
log "  5:00 Sun    - BTRFS scrub (weekly)"
log "  5:00 1st    - BTRFS balance (monthly)"
log "  6:00 1st    - Restore test (monthly, after backup)"
log "  5:00 Wed    - Restic integrity check (weekly)"
log "  3:00 Sun    - Docker system prune (weekly)"
