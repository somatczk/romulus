#!/bin/bash
set -euo pipefail
export PATH="$PATH:/DATA/bin"
export XDG_CACHE_HOME="/DATA/.cache"

# Monthly automated restore test
# Restores latest restic snapshot to temp dir, validates, cleans up

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../stacks/.env"

NTFY_URL="https://notify.${DOMAIN}/backups"
RESTORE_DIR=$(mktemp -d "/tmp/restore-test-XXXXXX")

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
    notify "Restore Test PASSED" "Monthly restore test passed. Restored size: ${RESTORE_SIZE}. All validations OK." "low"
else
    log "Restore test FAILED - ${ERRORS} validation(s) failed"
    notify "Restore Test FAILED" "Monthly restore test had ${ERRORS} failure(s). Check logs for details." "high"
    exit 1
fi
