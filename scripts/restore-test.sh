#!/bin/bash
set -euo pipefail
export PATH="$PATH:/usr/local/bin"
export RESTIC_CACHE_DIR=/var/cache/restic

# Monthly automated restore test
# Restores latest restic snapshot to temp dir, validates, cleans up

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/env.sh" RESTIC_PASSWORD

: "${HDD:?HDD must be set in stacks/host.env}"
NTFY_URL="https://notify.${DOMAIN}/backups"
mkdir -p "${HDD}/restore-test"
RESTORE_DIR=$(mktemp -d "${HDD}/restore-test/run-XXXXXX")
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
START_TIME=$(date +%s)

export RESTIC_REPOSITORY="${HDD}/backups/restic-repo"
export RESTIC_PASSWORD="${RESTIC_PASSWORD}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [restore-test] $1"
}

notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    curl -sf -H "Title: ${title}" -H "Priority: ${priority}" -d "${message}" "${NTFY_URL}" || true
}

write_metrics() {
    local success="$1"
    local errors="$2"
    local duration=$(( $(date +%s) - START_TIME ))
    local now
    now=$(date +%s)
    local tmpfile="${METRICS_DIR}/restore_test.prom.$$"
    mkdir -p "${METRICS_DIR}"
    cat > "${tmpfile}" <<PROM
# HELP homelab_restore_test_success Whether the last restore test succeeded (1=success, 0=failure).
# TYPE homelab_restore_test_success gauge
homelab_restore_test_success ${success}
# HELP homelab_restore_test_duration_seconds Duration of the last restore test in seconds.
# TYPE homelab_restore_test_duration_seconds gauge
homelab_restore_test_duration_seconds ${duration}
# HELP homelab_restore_test_last_run_timestamp Unix timestamp of the last restore test run.
# TYPE homelab_restore_test_last_run_timestamp gauge
homelab_restore_test_last_run_timestamp ${now}
# HELP homelab_restore_test_errors_total Number of validation errors in the last restore test.
# TYPE homelab_restore_test_errors_total gauge
homelab_restore_test_errors_total ${errors}
PROM
    mv "${tmpfile}" "${METRICS_DIR}/restore_test.prom"
}

cleanup() {
    log "Cleaning up restore test directory..."
    rm -rf "${RESTORE_DIR}"
    log "Cleanup complete"
}
trap cleanup EXIT

ERRORS=0

log "Starting monthly restore test..."
log "Restore directory: ${RESTORE_DIR}"

# Restore latest snapshot
# The restore lands on the backup HDD: refuse if it would not fit with 10% to spare.
NEED=$(restic stats latest --mode restore-size --json | jq -r .total_size) || NEED=""
if ! [[ "$NEED" =~ ^[0-9]+$ ]]; then
    log "ERROR: could not size the latest snapshot (got '${NEED}')"
    notify "Restore test failed" "Could not size the latest snapshot" "high"
    exit 1
fi
FREE=$(( $(df --output=avail -B1 "${HDD}" | tail -1) ))
if (( NEED + NEED / 10 > FREE )); then
    log "ERROR: restore needs ${NEED} bytes, ${FREE} free on ${HDD}"
    notify "Restore test skipped" "Not enough space on ${HDD}: need ${NEED}, free ${FREE}" "high"
    exit 1
fi

log "Restoring latest snapshot..."
restic restore latest --target "${RESTORE_DIR}" --verbose 2>&1
log "Restore complete"

# Validate key files and directories exist
log "Validating restored data..."

EXPECTED_DIRS=(
    "backups/db-dumps"
    "notifications"
    "utilities"
)

for dir in "${EXPECTED_DIRS[@]}"; do
    # Find the restored APPDATA path (restic preserves full paths)
    FOUND=$(find "${RESTORE_DIR}" -type d -path "*/${dir}" | head -1)
    if [ -n "${FOUND}" ]; then
        log "  OK: ${dir} directory found"
    else
        log "  FAIL: ${dir} directory missing"
        ERRORS=$((ERRORS + 1))
    fi
done

# Verify database dumps exist and are non-empty
DUMP_DIR=$(find "${RESTORE_DIR}" -type d -name "db-dumps" | head -1)
if [ -n "${DUMP_DIR}" ]; then
    DUMP_COUNT=$(find "${DUMP_DIR}" -name "*.sql" -size +0 | wc -l)
    if [ "${DUMP_COUNT}" -gt 0 ]; then
        log "  OK: Found ${DUMP_COUNT} non-empty database dump(s)"
    else
        log "  FAIL: No valid database dumps found"
        ERRORS=$((ERRORS + 1))
    fi
fi

# Check restic repository integrity
log "Checking restic repository integrity..."
if restic check 2>&1; then
    log "  OK: Repository integrity verified"
else
    log "  FAIL: Repository integrity check failed"
    ERRORS=$((ERRORS + 1))
fi

# Report results
RESTORE_SIZE=$(du -sh "${RESTORE_DIR}" 2>/dev/null | cut -f1)

if [ "${ERRORS}" -eq 0 ]; then
    log "Restore test PASSED - all validations successful"
    write_metrics 1 0
    notify "Restore Test PASSED" "Monthly restore test passed. Restored size: ${RESTORE_SIZE}. All validations OK." "low"
else
    log "Restore test FAILED - ${ERRORS} validation(s) failed"
    write_metrics 0 "${ERRORS}"
    notify "Restore Test FAILED" "Monthly restore test had ${ERRORS} failure(s). Check logs for details." "high"
    exit 1
fi
