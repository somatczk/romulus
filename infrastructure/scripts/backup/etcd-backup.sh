#!/bin/bash
# Comprehensive etcd Backup Script for Kubernetes Clusters
# Supports both stacked etcd and external etcd deployments

set -euo pipefail

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/var/lib/etcd-backup}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-https://127.0.0.1:2379}"
ETCD_CERT_FILE="${ETCD_CERT_FILE:-/etc/kubernetes/pki/etcd/peer.crt}"
ETCD_KEY_FILE="${ETCD_KEY_FILE:-/etc/kubernetes/pki/etcd/peer.key}"
ETCD_CA_FILE="${ETCD_CA_FILE:-/etc/kubernetes/pki/etcd/ca.crt}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-etcd-backups}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
LOG_FILE="${LOG_FILE:-/var/log/etcd-backup.log}"
COMPRESSION="${COMPRESSION:-gzip}"  # gzip, xz, or none
ENCRYPTION_KEY="${ENCRYPTION_KEY:-}"  # GPG key ID for encryption

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1${NC}" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') - WARN: $1${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') - SUCCESS: $1${NC}" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}$(date '+%Y-%m-%d %H:%M:%S') - INFO: $1${NC}" | tee -a "$LOG_FILE"
}

send_alert() {
    local message="$1"
    local severity="$2"
    
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        curl -X POST "$ALERT_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{
                \"service\": \"etcd-backup\",
                \"message\": \"$message\",
                \"severity\": \"$severity\",
                \"timestamp\": \"$(date -Iseconds)\",
                \"hostname\": \"$(hostname)\"
            }" 2>/dev/null || log_warn "Failed to send alert"
    fi
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v etcdctl >/dev/null 2>&1; then
        missing_deps+=("etcdctl")
    fi
    
    if [[ "$COMPRESSION" == "gzip" ]] && ! command -v gzip >/dev/null 2>&1; then
        missing_deps+=("gzip")
    elif [[ "$COMPRESSION" == "xz" ]] && ! command -v xz >/dev/null 2>&1; then
        missing_deps+=("xz")
    fi
    
    if [[ -n "$ENCRYPTION_KEY" ]] && ! command -v gpg >/dev/null 2>&1; then
        missing_deps+=("gpg")
    fi
    
    if [[ -n "$S3_BUCKET" ]] && ! command -v aws >/dev/null 2>&1; then
        missing_deps+=("aws")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi
    
    log_success "All dependencies satisfied"
}

check_etcd_health() {
    log_info "Checking etcd cluster health..."
    
    if ! etcdctl \
        --endpoints="$ETCD_ENDPOINTS" \
        --cert="$ETCD_CERT_FILE" \
        --key="$ETCD_KEY_FILE" \
        --cacert="$ETCD_CA_FILE" \
        endpoint health &>/dev/null; then
        log_error "etcd cluster is unhealthy"
        send_alert "etcd cluster health check failed" "critical"
        return 1
    fi
    
    log_success "etcd cluster is healthy"
}

get_etcd_version() {
    etcdctl \
        --endpoints="$ETCD_ENDPOINTS" \
        --cert="$ETCD_CERT_FILE" \
        --key="$ETCD_KEY_FILE" \
        --cacert="$ETCD_CA_FILE" \
        version --cluster 2>/dev/null | grep -o 'etcd Version: [0-9.]*' | head -1 | cut -d' ' -f3 || echo "unknown"
}

get_cluster_id() {
    etcdctl \
        --endpoints="$ETCD_ENDPOINTS" \
        --cert="$ETCD_CERT_FILE" \
        --key="$ETCD_KEY_FILE" \
        --cacert="$ETCD_CA_FILE" \
        endpoint status --write-out=table 2>/dev/null | \
        awk '/CLUSTER/{getline; print $2}' | head -1 || echo "unknown"
}

create_snapshot() {
    local timestamp="$1"
    local backup_file="$2"
    
    log_info "Creating etcd snapshot..."
    
    # Set ETCDCTL_API version for compatibility
    export ETCDCTL_API=3
    
    if ! etcdctl \
        --endpoints="$ETCD_ENDPOINTS" \
        --cert="$ETCD_CERT_FILE" \
        --key="$ETCD_KEY_FILE" \
        --cacert="$ETCD_CA_FILE" \
        snapshot save "$backup_file"; then
        log_error "Failed to create etcd snapshot"
        send_alert "etcd snapshot creation failed" "critical"
        return 1
    fi
    
    log_success "etcd snapshot created: $backup_file"
}

verify_snapshot() {
    local backup_file="$1"
    
    log_info "Verifying snapshot integrity..."
    
    export ETCDCTL_API=3
    
    if ! etcdctl snapshot status "$backup_file" >/dev/null 2>&1; then
        log_error "Snapshot verification failed: $backup_file"
        send_alert "etcd snapshot verification failed" "critical"
        return 1
    fi
    
    local snapshot_info
    snapshot_info=$(etcdctl snapshot status "$backup_file" --write-out=json 2>/dev/null || echo '{}')
    local total_keys
    total_keys=$(echo "$snapshot_info" | grep -o '"totalKey":[0-9]*' | cut -d':' -f2 || echo "0")
    
    log_success "Snapshot verified successfully - Total keys: $total_keys"
}

compress_backup() {
    local backup_file="$1"
    
    if [[ "$COMPRESSION" == "none" ]]; then
        echo "$backup_file"
        return 0
    fi
    
    log_info "Compressing backup with $COMPRESSION..."
    
    local compressed_file
    
    case "$COMPRESSION" in
        "gzip")
            compressed_file="${backup_file}.gz"
            if ! gzip -9 "$backup_file"; then
                log_error "Failed to compress backup with gzip"
                return 1
            fi
            ;;
        "xz")
            compressed_file="${backup_file}.xz"
            if ! xz -9 "$backup_file"; then
                log_error "Failed to compress backup with xz"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown compression method: $COMPRESSION, skipping compression"
            compressed_file="$backup_file"
            ;;
    esac
    
    log_success "Backup compressed: $compressed_file"
    echo "$compressed_file"
}

encrypt_backup() {
    local backup_file="$1"
    
    if [[ -z "$ENCRYPTION_KEY" ]]; then
        echo "$backup_file"
        return 0
    fi
    
    log_info "Encrypting backup with GPG..."
    
    local encrypted_file="${backup_file}.gpg"
    
    if ! gpg --trust-model always --encrypt --recipient "$ENCRYPTION_KEY" \
         --output "$encrypted_file" "$backup_file"; then
        log_error "Failed to encrypt backup"
        return 1
    fi
    
    # Remove unencrypted file after successful encryption
    rm -f "$backup_file"
    
    log_success "Backup encrypted: $encrypted_file"
    echo "$encrypted_file"
}

upload_to_s3() {
    local backup_file="$1"
    local timestamp="$2"
    
    if [[ -z "$S3_BUCKET" ]]; then
        return 0
    fi
    
    log_info "Uploading backup to S3..."
    
    local s3_key="${S3_PREFIX}/${timestamp}/$(basename "$backup_file")"
    
    if ! aws s3 cp "$backup_file" "s3://${S3_BUCKET}/${s3_key}" \
         --storage-class STANDARD_IA; then
        log_error "Failed to upload backup to S3"
        send_alert "S3 upload failed for etcd backup" "warning"
        return 1
    fi
    
    # Upload metadata
    local metadata_file="/tmp/etcd-backup-metadata-${timestamp}.json"
    cat > "$metadata_file" <<EOF
{
  "timestamp": "${timestamp}",
  "hostname": "$(hostname)",
  "etcd_version": "$(get_etcd_version)",
  "cluster_id": "$(get_cluster_id)",
  "backup_file": "$(basename "$backup_file")",
  "file_size": $(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0"),
  "compression": "$COMPRESSION",
  "encrypted": $([ -n "$ENCRYPTION_KEY" ] && echo "true" || echo "false")
}
EOF
    
    aws s3 cp "$metadata_file" "s3://${S3_BUCKET}/${S3_PREFIX}/${timestamp}/metadata.json"
    rm -f "$metadata_file"
    
    log_success "Backup uploaded to S3: s3://${S3_BUCKET}/${s3_key}"
}

cleanup_old_backups() {
    log_info "Cleaning up old backups (retention: ${RETENTION_DAYS} days)..."
    
    # Local cleanup
    if [[ -d "$BACKUP_DIR" ]]; then
        find "$BACKUP_DIR" -name "etcd-backup-*" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
        local deleted_count
        deleted_count=$(find "$BACKUP_DIR" -name "etcd-backup-*" -type f -mtime +"$RETENTION_DAYS" 2>/dev/null | wc -l || echo "0")
        log_info "Deleted $deleted_count old local backup files"
    fi
    
    # S3 cleanup
    if [[ -n "$S3_BUCKET" ]]; then
        local cutoff_date
        cutoff_date=$(date -d "$RETENTION_DAYS days ago" '+%Y-%m-%d' 2>/dev/null || \
                     date -v "-${RETENTION_DAYS}d" '+%Y-%m-%d' 2>/dev/null || \
                     echo "")
        
        if [[ -n "$cutoff_date" ]]; then
            # List and delete old S3 objects
            aws s3api list-objects-v2 \
                --bucket "$S3_BUCKET" \
                --prefix "$S3_PREFIX/" \
                --query "Contents[?LastModified<='${cutoff_date}T23:59:59.000Z'].Key" \
                --output text 2>/dev/null | \
            while read -r key; do
                if [[ -n "$key" && "$key" != "None" ]]; then
                    aws s3 rm "s3://${S3_BUCKET}/${key}" 2>/dev/null || true
                fi
            done
        fi
    fi
    
    log_success "Old backup cleanup completed"
}

generate_backup_report() {
    local backup_file="$1"
    local timestamp="$2"
    
    local file_size
    file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
    local file_size_mb
    file_size_mb=$(echo "scale=2; $file_size / 1048576" | bc 2>/dev/null || echo "0")
    
    cat <<EOF

========================
ETCD BACKUP REPORT
========================
Timestamp: $timestamp
Hostname: $(hostname)
Backup File: $(basename "$backup_file")
File Size: ${file_size_mb} MB
Compression: $COMPRESSION
Encryption: $([ -n "$ENCRYPTION_KEY" ] && echo "Enabled" || echo "Disabled")
S3 Upload: $([ -n "$S3_BUCKET" ] && echo "Enabled" || echo "Disabled")
ETCD Version: $(get_etcd_version)
Cluster ID: $(get_cluster_id)
========================

EOF
}

main() {
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    
    log_info "Starting etcd backup process (PID: $$)"
    log_info "Backup timestamp: $timestamp"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Check prerequisites
    if ! check_dependencies; then
        exit 1
    fi
    
    if ! check_etcd_health; then
        exit 1
    fi
    
    # Create backup filename
    local backup_file="${BACKUP_DIR}/etcd-backup-${timestamp}.db"
    
    # Perform backup steps
    if ! create_snapshot "$timestamp" "$backup_file"; then
        exit 1
    fi
    
    if ! verify_snapshot "$backup_file"; then
        rm -f "$backup_file"
        exit 1
    fi
    
    # Compress backup
    backup_file=$(compress_backup "$backup_file")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Encrypt backup
    backup_file=$(encrypt_backup "$backup_file")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Upload to S3
    upload_to_s3 "$backup_file" "$timestamp"
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Generate report
    generate_backup_report "$backup_file" "$timestamp" | tee -a "$LOG_FILE"
    
    log_success "etcd backup completed successfully"
    send_alert "etcd backup completed successfully" "info"
}

# Handle signals gracefully
trap 'log_info "etcd backup interrupted"; exit 130' SIGINT SIGTERM

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            cat <<EOF
Usage: $0 [options]

Options:
  --help, -h          Show this help message
  --dry-run          Simulate backup without actually creating files
  --verify-only FILE  Only verify an existing snapshot file
  --list-backups     List available backups in backup directory and S3

Environment Variables:
  BACKUP_DIR         Local backup directory (default: /var/lib/etcd-backup)
  RETENTION_DAYS     Days to keep backups (default: 7)
  ETCD_ENDPOINTS     etcd endpoints (default: https://127.0.0.1:2379)
  ETCD_CERT_FILE     etcd client certificate file
  ETCD_KEY_FILE      etcd client key file  
  ETCD_CA_FILE       etcd CA certificate file
  S3_BUCKET          S3 bucket for backup storage
  S3_PREFIX          S3 key prefix (default: etcd-backups)
  ALERT_WEBHOOK      Webhook URL for alerts
  COMPRESSION        Compression method: gzip, xz, none (default: gzip)
  ENCRYPTION_KEY     GPG key ID for encryption
  LOG_FILE           Log file path (default: /var/log/etcd-backup.log)
EOF
            exit 0
            ;;
        --dry-run)
            log_info "Dry run mode - no files will be created"
            DRY_RUN=true
            ;;
        --verify-only)
            if [[ -z "${2:-}" ]]; then
                log_error "--verify-only requires a file path"
                exit 1
            fi
            verify_snapshot "$2"
            exit $?
            ;;
        --list-backups)
            echo "Local backups in $BACKUP_DIR:"
            ls -la "$BACKUP_DIR"/etcd-backup-* 2>/dev/null || echo "No local backups found"
            
            if [[ -n "$S3_BUCKET" ]]; then
                echo -e "\nS3 backups in s3://$S3_BUCKET/$S3_PREFIX:"
                aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" --recursive 2>/dev/null || echo "No S3 backups found or AWS not configured"
            fi
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# Run main function if no special options
if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "Dry run completed - no actual backup performed"
else
    main "$@"
fi
