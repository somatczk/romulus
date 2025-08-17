#!/bin/bash

# Homeserver Infrastructure Backup Script
# 
# Purpose: Automated backup of critical homeserver data and configurations
# Features: Database dumps, configuration backup, cloud storage, encryption
# Usage: ./scripts/backup.sh [--type full|config|database] [--dry-run]
# 
# Backup Components:
# 1. Database dumps (MariaDB, SQLite databases)
# 2. Configuration files and Docker Compose definitions
# 3. Application data and user settings
# 4. SSL certificates and security keys
# 5. Monitoring data and dashboards
#
# Storage Strategy:
# - Local staging on SSD for preparation
# - Cloud storage for offsite backup
# - Encryption for all backup data
# - Retention policy with automatic cleanup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DATE=$(date +%Y%m%d-%H%M%S)
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml"

# Default settings
BACKUP_TYPE="full"
DRY_RUN=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    local deps=("docker" "docker-compose" "tar" "gzip" "openssl")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "Required dependency '$dep' not found"
            exit 1
        fi
    done
}

load_environment() {
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        source "$PROJECT_DIR/.env"
    else
        log_error "Environment file not found: $PROJECT_DIR/.env"
        exit 1
    fi
    
    # Validate required variables
    required_vars=(
        "SSD_PATH"
        "BACKUP_ENCRYPTION_KEY"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required environment variable '$var' is not set"
            exit 1
        fi
    done
}

create_backup_structure() {
    local backup_dir="$1"
    
    mkdir -p "$backup_dir"/{databases,configs,data,logs}
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Created backup structure in $backup_dir"
    fi
}

backup_mariadb() {
    local backup_dir="$1"
    
    log_info "Backing up MariaDB databases..."
    
    # Get list of databases
    local databases
    databases=$(docker exec mariadb mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SHOW DATABASES;" | tail -n +2 | grep -E -v '^(information_schema|mysql|performance_schema|sys)$')
    
    for db in $databases; do
        log_info "  Dumping database: $db"
        
        if [[ "$DRY_RUN" == "false" ]]; then
            docker exec mariadb mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" \
                --single-transaction \
                --routines \
                --triggers \
                --events \
                "$db" > "$backup_dir/databases/${db}.sql"
            
            # Compress the dump
            gzip "$backup_dir/databases/${db}.sql"
        fi
    done
    
    log_success "MariaDB backup completed"
}

backup_redis() {
    local backup_dir="$1"
    
    log_info "Backing up Redis data..."
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Trigger Redis save
        docker exec redis redis-cli --no-auth-warning -a "${REDIS_PASSWORD}" BGSAVE
        
        # Wait for save to complete
        while [[ "$(docker exec redis redis-cli --no-auth-warning -a "${REDIS_PASSWORD}" LASTSAVE)" == "$(docker exec redis redis-cli --no-auth-warning -a "${REDIS_PASSWORD}" LASTSAVE)" ]]; do
            sleep 1
        done
        
        # Copy Redis dump
        docker cp redis:/data/dump.rdb "$backup_dir/databases/redis-dump.rdb"
        gzip "$backup_dir/databases/redis-dump.rdb"
    fi
    
    log_success "Redis backup completed"
}

backup_sqlite_databases() {
    local backup_dir="$1"
    
    log_info "Backing up SQLite databases..."
    
    # Authelia database
    if [[ -f "${SSD_PATH}/config/authelia/db.sqlite3" ]]; then
        log_info "  Backing up Authelia database"
        if [[ "$DRY_RUN" == "false" ]]; then
            cp "${SSD_PATH}/config/authelia/db.sqlite3" "$backup_dir/databases/authelia.sqlite3"
            gzip "$backup_dir/databases/authelia.sqlite3"
        fi
    fi
    
    # Uptime Kuma database
    if [[ -f "${SSD_PATH}/monitoring/uptime-kuma/kuma.db" ]]; then
        log_info "  Backing up Uptime Kuma database"
        if [[ "$DRY_RUN" == "false" ]]; then
            cp "${SSD_PATH}/monitoring/uptime-kuma/kuma.db" "$backup_dir/databases/uptime-kuma.db"
            gzip "$backup_dir/databases/uptime-kuma.db"
        fi
    fi
    
    log_success "SQLite databases backup completed"
}

backup_configurations() {
    local backup_dir="$1"
    
    log_info "Backing up configurations..."
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Docker Compose files
        cp "$PROJECT_DIR"/docker-compose*.yml "$backup_dir/configs/"
        
        # Configuration directory
        cp -r "$PROJECT_DIR/configs" "$backup_dir/"
        
        # Scripts directory
        cp -r "$PROJECT_DIR/scripts" "$backup_dir/"
        
        # Environment template (not the actual .env with secrets)
        cp "$PROJECT_DIR/.env.example" "$backup_dir/configs/"
        
        # Documentation
        if [[ -d "$PROJECT_DIR/docs" ]]; then
            cp -r "$PROJECT_DIR/docs" "$backup_dir/"
        fi
        
        # README and other documentation files
        cp "$PROJECT_DIR/README.md" "$backup_dir/" 2>/dev/null || true
    fi
    
    log_success "Configuration backup completed"
}

backup_ssl_certificates() {
    local backup_dir="$1"
    
    log_info "Backing up SSL certificates..."
    
    if [[ -d "${SSD_PATH}/caddy/data" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            cp -r "${SSD_PATH}/caddy/data" "$backup_dir/configs/caddy-certificates"
        fi
        log_success "SSL certificates backup completed"
    else
        log_warning "SSL certificates directory not found"
    fi
}

backup_application_data() {
    local backup_dir="$1"
    
    log_info "Backing up application data..."
    
    # Critical application configs (excluding large media files)
    local app_configs=(
        "${SSD_PATH}/config/plex/Library/Application Support/Plex Media Server/Preferences.xml"
        "${SSD_PATH}/config/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/"
        "${SSD_PATH}/config/qbittorrent/qBittorrent/config/"
        "${SSD_PATH}/config/teamspeak/serverkey.dat"
        "${SSD_PATH}/config/teamspeak/ts3server.sqlitedb"
        "${SSD_PATH}/monitoring/grafana/grafana.db"
        "${SSD_PATH}/monitoring/prometheus/prometheus.yml"
    )
    
    for config_path in "${app_configs[@]}"; do
        if [[ -e "$config_path" ]]; then
            local relative_path="${config_path#${SSD_PATH}/}"
            local target_dir="$backup_dir/data/$(dirname "$relative_path")"
            
            if [[ "$DRY_RUN" == "false" ]]; then
                mkdir -p "$target_dir"
                cp -r "$config_path" "$target_dir/"
            fi
            
            if [[ "$VERBOSE" == "true" ]]; then
                log_info "  Backed up: $relative_path"
            fi
        fi
    done
    
    log_success "Application data backup completed"
}

backup_monitoring_data() {
    local backup_dir="$1"
    
    log_info "Backing up monitoring data..."
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Grafana dashboards and data sources
        if [[ -d "${SSD_PATH}/monitoring/grafana" ]]; then
            mkdir -p "$backup_dir/data/monitoring"
            cp -r "${SSD_PATH}/monitoring/grafana" "$backup_dir/data/monitoring/"
        fi
        
        # Prometheus configuration (not the large time-series data)
        if [[ -f "${SSD_PATH}/monitoring/prometheus/prometheus.yml" ]]; then
            cp "${SSD_PATH}/monitoring/prometheus/prometheus.yml" "$backup_dir/data/monitoring/"
        fi
        
        # Alertmanager configuration
        if [[ -d "${SSD_PATH}/monitoring/alertmanager" ]]; then
            cp -r "${SSD_PATH}/monitoring/alertmanager" "$backup_dir/data/monitoring/"
        fi
    fi
    
    log_success "Monitoring data backup completed"
}

create_archive() {
    local backup_dir="$1"
    local archive_name="homeserver-backup-${BACKUP_DATE}.tar.gz"
    local archive_path="${SSD_PATH}/backups/$archive_name"
    
    log_info "Creating compressed archive..."
    
    if [[ "$DRY_RUN" == "false" ]]; then
        mkdir -p "${SSD_PATH}/backups"
        
        # Create tar archive with compression
        tar -czf "$archive_path" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"
        
        log_info "Archive created: $archive_path"
        log_info "Archive size: $(du -h "$archive_path" | cut -f1)"
    fi
    
    echo "$archive_path"
}

encrypt_archive() {
    local archive_path="$1"
    local encrypted_path="${archive_path}.enc"
    
    log_info "Encrypting backup archive..."
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Use AES-256-CBC encryption
        openssl enc -aes-256-cbc -salt -in "$archive_path" -out "$encrypted_path" -k "$BACKUP_ENCRYPTION_KEY"
        
        # Remove unencrypted archive
        rm "$archive_path"
        
        log_success "Archive encrypted: $encrypted_path"
    fi
    
    echo "$encrypted_path"
}

upload_to_cloud() {
    local encrypted_path="$1"
    
    log_info "Uploading to cloud storage..."
    
    # Check if cloud storage is configured
    if [[ -n "${B2_ACCOUNT_ID:-}" && -n "${B2_ACCOUNT_KEY:-}" ]]; then
        upload_to_b2 "$encrypted_path"
    elif [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        upload_to_s3 "$encrypted_path"
    else
        log_warning "No cloud storage configured, keeping local backup only"
        return 0
    fi
}

upload_to_b2() {
    local encrypted_path="$1"
    
    if ! command -v b2 &> /dev/null; then
        log_warning "Backblaze B2 CLI not installed, skipping cloud upload"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Authorize B2
        b2 authorize-account "$B2_ACCOUNT_ID" "$B2_ACCOUNT_KEY"
        
        # Upload file
        b2 upload-file "$B2_BUCKET_NAME" "$encrypted_path" "homeserver-backups/$(basename "$encrypted_path")"
        
        log_success "Uploaded to Backblaze B2"
    fi
}

upload_to_s3() {
    local encrypted_path="$1"
    
    if ! command -v aws &> /dev/null; then
        log_warning "AWS CLI not installed, skipping cloud upload"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Upload to S3
        aws s3 cp "$encrypted_path" "s3://${S3_BUCKET_NAME}/homeserver-backups/$(basename "$encrypted_path")"
        
        log_success "Uploaded to AWS S3"
    fi
}

cleanup_old_backups() {
    local retention_days=30
    
    log_info "Cleaning up old backups (retention: $retention_days days)..."
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Clean up local backups
        find "${SSD_PATH}/backups" -name "homeserver-backup-*.tar.gz.enc" -type f -mtime +$retention_days -delete
        
        # Clean up cloud backups (if configured)
        if [[ -n "${B2_BUCKET_NAME:-}" ]] && command -v b2 &> /dev/null; then
            # B2 cleanup would need additional logic to list and delete old files
            log_info "  Cloud cleanup for B2 requires manual implementation"
        fi
        
        if [[ -n "${S3_BUCKET_NAME:-}" ]] && command -v aws &> /dev/null; then
            # S3 cleanup - delete files older than retention period
            local cutoff_date
            cutoff_date=$(date -d "$retention_days days ago" +%Y-%m-%d)
            
            aws s3 ls "s3://${S3_BUCKET_NAME}/homeserver-backups/" | while read -r line; do
                local file_date file_name
                file_date=$(echo "$line" | awk '{print $1}')
                file_name=$(echo "$line" | awk '{print $4}')
                
                if [[ "$file_date" < "$cutoff_date" ]]; then
                    aws s3 rm "s3://${S3_BUCKET_NAME}/homeserver-backups/$file_name"
                    log_info "  Deleted old backup: $file_name"
                fi
            done
        fi
    fi
    
    log_success "Cleanup completed"
}

perform_backup() {
    local temp_backup_dir="/tmp/homeserver-backup-$BACKUP_DATE"
    
    log_info "Starting backup process..."
    log_info "Backup type: $BACKUP_TYPE"
    log_info "Dry run: $DRY_RUN"
    
    # Create backup structure
    create_backup_structure "$temp_backup_dir"
    
    # Perform backup based on type
    case "$BACKUP_TYPE" in
        "full")
            backup_mariadb "$temp_backup_dir"
            backup_redis "$temp_backup_dir"
            backup_sqlite_databases "$temp_backup_dir"
            backup_configurations "$temp_backup_dir"
            backup_ssl_certificates "$temp_backup_dir"
            backup_application_data "$temp_backup_dir"
            backup_monitoring_data "$temp_backup_dir"
            ;;
        "database")
            backup_mariadb "$temp_backup_dir"
            backup_redis "$temp_backup_dir"
            backup_sqlite_databases "$temp_backup_dir"
            ;;
        "config")
            backup_configurations "$temp_backup_dir"
            backup_ssl_certificates "$temp_backup_dir"
            ;;
        *)
            log_error "Unknown backup type: $BACKUP_TYPE"
            exit 1
            ;;
    esac
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Create and encrypt archive
        local archive_path
        archive_path=$(create_archive "$temp_backup_dir")
        
        local encrypted_path
        encrypted_path=$(encrypt_archive "$archive_path")
        
        # Upload to cloud storage
        upload_to_cloud "$encrypted_path"
        
        # Cleanup
        cleanup_old_backups
        
        # Remove temporary directory
        rm -rf "$temp_backup_dir"
        
        log_success "Backup completed successfully!"
        log_info "Backup location: $encrypted_path"
    else
        log_info "Dry run completed - no files were actually backed up"
        rm -rf "$temp_backup_dir"
    fi
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --type)
                BACKUP_TYPE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --type [full|config|database]  Type of backup to perform (default: full)"
                echo "  --dry-run                       Show what would be backed up without doing it"
                echo "  --verbose                       Show detailed output"
                echo "  --help                          Show this help message"
                echo ""
                echo "Backup types:"
                echo "  full      - Complete backup including databases, configs, and application data"
                echo "  config    - Configuration files and certificates only"
                echo "  database  - Database dumps only"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Validate backup type
    if [[ ! "$BACKUP_TYPE" =~ ^(full|config|database)$ ]]; then
        log_error "Invalid backup type: $BACKUP_TYPE"
        exit 1
    fi
    
    cd "$PROJECT_DIR"
    
    # Check dependencies and load environment
    check_dependencies
    load_environment
    
    # Perform backup
    perform_backup
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi