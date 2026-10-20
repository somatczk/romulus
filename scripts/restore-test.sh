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
    if [ -n "${HYDRA_CID:-}" ]; then
        docker rm -fv "${HYDRA_CID}" >/dev/null 2>&1 || true
    fi
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
    DUMP_COUNT=$(find "${DUMP_DIR}" \( -name "*.sql" -o -name "*.dump" \) -size +0 | wc -l)
    if [ "${DUMP_COUNT}" -gt 0 ]; then
        log "  OK: Found ${DUMP_COUNT} non-empty database dump(s)"
    else
        log "  FAIL: No valid database dumps found"
        ERRORS=$((ERRORS + 1))
    fi
fi

# restore newest hydra dump into a throwaway TimescaleDB; check alembic_version and .counts
restore_hydra() {
    local dump counts img table want got version i
    dump=$(find "${DUMP_DIR:-/nonexistent}" -maxdepth 1 -name 'hydra_*.dump' -size +0 2>/dev/null | sort | tail -1)
    [ -n "${dump}" ] || { log "  FAIL: no hydra .dump in db-dumps"; return 1; }
    counts="${dump%.dump}.counts"
    [ -s "${counts}" ] || { log "  FAIL: $(basename "${counts}") missing"; return 1; }
    img=$(awk '/^FROM /{print $2}' "${SCRIPT_DIR}/../stacks/hydra/timescaledb/Dockerfile")
    log "Restoring $(basename "${dump}") into a throwaway ${img}..."
    HYDRA_CID=$(docker run --rm -d --network none -e POSTGRES_DB=hydra -e POSTGRES_PASSWORD=restore-test \
        -v "${DUMP_DIR}:/dumps:ro" "${img}") || { log "  FAIL: cannot start ${img}"; return 1; }
    # TCP only answers once the entrypoint's init server has handed over to the real one
    for i in $(seq 1 120); do
        docker exec "${HYDRA_CID}" pg_isready -q -h 127.0.0.1 -U postgres && break
        [ "${i}" -lt 120 ] || { log "  FAIL: throwaway TimescaleDB not ready in 120s"; return 1; }
        sleep 1
    done
    hsql() { docker exec "${HYDRA_CID}" psql -U postgres -d hydra -v ON_ERROR_STOP=1 -At "$@"; }
    hsql -c "CREATE EXTENSION IF NOT EXISTS timescaledb" -c "SELECT timescaledb_pre_restore()" >/dev/null \
        || { log "  FAIL: timescaledb_pre_restore"; return 1; }
    # shortcut: pg_restore errors are fatal with no benign-error filter, add one after the first on-box run
    docker exec "${HYDRA_CID}" pg_restore -U postgres -d hydra --no-owner --no-privileges \
        "/dumps/$(basename "${dump}")" 2>&1 || { log "  FAIL: pg_restore $(basename "${dump}")"; return 1; }
    hsql -c "SELECT timescaledb_post_restore()" >/dev/null || { log "  FAIL: timescaledb_post_restore"; return 1; }
    version=$(hsql -c "SELECT version_num FROM alembic_version") || { log "  FAIL: alembic_version missing"; return 1; }
    [ "$(wc -l <<< "${version}")" -eq 1 ] && [ -n "${version}" ] \
        || { log "  FAIL: alembic_version must hold one row, got '${version}'"; return 1; }
    log "  OK: alembic_version ${version}"
    while read -r table want; do
        got=$(hsql -c "SELECT count(*) FROM ${table}") || { log "  FAIL: cannot count ${table}"; return 1; }
        if ! [[ "${want}" =~ ^[0-9]+$ && "${got}" =~ ^[0-9]+$ ]] || (( got < want )); then
            log "  FAIL: ${table} restored ${got} rows, ${want} counted at dump time"
            return 1
        fi
        log "  OK: ${table} restored ${got} rows (${want} counted at dump time)"
    done < "${counts}"
}

if restore_hydra; then
    log "  OK: hydra dump restored"
else
    ERRORS=$((ERRORS + 1))
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
