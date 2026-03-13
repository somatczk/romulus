#!/bin/bash
set -euo pipefail
export PATH="$PATH:/DATA/bin"
export XDG_CACHE_HOME="/DATA/.cache"

# Daily backup script: database dumps + restic backup
# Runs at 3:00 AM via cron

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../stacks/.env"

BACKUP_DIR="${APPDATA}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NTFY_URL="https://notify.${DOMAIN}/backups"
LOG_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.log"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
START_TIME=$(date +%s)

export RESTIC_REPOSITORY="${HDD}/backups/restic-repo"
export RESTIC_PASSWORD="${RESTIC_PASSWORD}"

mkdir -p "${BACKUP_DIR}/db-dumps"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    curl -sf -H "Title: ${title}" -H "Priority: ${priority}" -d "${message}" "${NTFY_URL}" || true
}

write_metrics() {
    local success="$1"
    local duration=$(( $(date +%s) - START_TIME ))
    local now
    now=$(date +%s)
    local tmpfile="${METRICS_DIR}/backup.prom.$$"
    mkdir -p "${METRICS_DIR}"
    cat > "${tmpfile}" <<PROM
# HELP homelab_backup_success Whether the last backup succeeded (1=success, 0=failure).
# TYPE homelab_backup_success gauge
homelab_backup_success ${success}
# HELP homelab_backup_duration_seconds Duration of the last backup run in seconds.
# TYPE homelab_backup_duration_seconds gauge
homelab_backup_duration_seconds ${duration}
# HELP homelab_backup_last_run_timestamp Unix timestamp of the last backup run.
# TYPE homelab_backup_last_run_timestamp gauge
homelab_backup_last_run_timestamp ${now}
PROM
    mv "${tmpfile}" "${METRICS_DIR}/backup.prom"
}

cleanup() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        log "ERROR: Backup failed with exit code ${exit_code}"
        notify "Backup FAILED" "Backup failed at $(date). Check ${LOG_FILE} for details." "urgent"
        write_metrics 0
    fi
}
trap cleanup EXIT

log "Starting backup..."

# Database dumps
log "Dumping Nextcloud database..."
docker exec nextcloud-db pg_dump -U nextcloud nextcloud \
    > "${BACKUP_DIR}/db-dumps/nextcloud_${TIMESTAMP}.sql"
log "Nextcloud database dump complete"

log "Dumping Immich database..."
docker exec immich-db pg_dump -U immich immich \
    > "${BACKUP_DIR}/db-dumps/immich_${TIMESTAMP}.sql"
log "Immich database dump complete"

log "Dumping TeamSpeak database..."
docker exec teamspeak-db mariadb-dump -u teamspeak -p"${TEAMSPEAK_DB_PASSWORD}" teamspeak \
    > "${BACKUP_DIR}/db-dumps/teamspeak_${TIMESTAMP}.sql"
log "TeamSpeak database dump complete"

log "Dumping Paperless database..."
docker exec paperless-db pg_dump -U paperless paperless \
    > "${BACKUP_DIR}/db-dumps/paperless_${TIMESTAMP}.sql"
log "Paperless database dump complete"

log "Dumping Hydra database..."
docker exec hydra-timescaledb pg_dump -U hydra hydra \
    > "${BACKUP_DIR}/db-dumps/hydra_${TIMESTAMP}.sql"
log "Hydra database dump complete"

# Clean up old database dumps (keep last 7)
find "${BACKUP_DIR}/db-dumps" -name "*.sql" -mtime +7 -delete

# Initialize restic repo if needed
if ! restic snapshots &>/dev/null; then
    log "Initializing restic repository..."
    restic init
fi

# Restic backup
log "Starting restic backup of ${APPDATA}..."
restic backup "${APPDATA}" \
    --exclude="${APPDATA}/*/cache" \
    --exclude="${APPDATA}/*/Cache" \
    --exclude="${APPDATA}/**/logs" \
    --tag "scheduled" \
    --verbose 2>&1 | tee -a "${LOG_FILE}"
log "Restic backup complete"

# Apply retention policy
log "Applying retention policy..."
restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --keep-yearly 1 \
    --prune \
    --verbose 2>&1 | tee -a "${LOG_FILE}"
log "Retention policy applied"

# Get stats for notification
SNAPSHOT_COUNT=$(restic snapshots --json | jq length)
REPO_SIZE=$(restic stats --json | jq -r '.total_size' | numfmt --to=iec 2>/dev/null || echo "unknown")

write_metrics 1

log "Backup completed successfully"
notify "Backup OK" "Backup completed at $(date). Snapshots: ${SNAPSHOT_COUNT}, Repo size: ${REPO_SIZE}" "low"
