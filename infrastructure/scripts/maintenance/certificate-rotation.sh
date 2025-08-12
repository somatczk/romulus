#!/bin/bash
# Comprehensive Certificate Rotation Script for Kubernetes Clusters
# Safely rotates certificates with backup and validation

set -euo pipefail

# Configuration
CERT_BACKUP_DIR="${CERT_BACKUP_DIR:-/var/lib/kubernetes/cert-backups}"
KUBE_PKI_DIR="${KUBE_PKI_DIR:-/etc/kubernetes/pki}"
KUBEADM_CONFIG="${KUBEADM_CONFIG:-/etc/kubernetes/kubeadm.yaml}"
ROTATION_TIMEOUT="${ROTATION_TIMEOUT:-300}"
VALIDATION_TIMEOUT="${VALIDATION_TIMEOUT:-120}"
RESTART_COMPONENTS="${RESTART_COMPONENTS:-true}"
BACKUP_CERTS="${BACKUP_CERTS:-true}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
LOG_FILE="${LOG_FILE:-/var/log/cert-rotation.log}"
KUBECONFIG="${KUBECONFIG:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
DRY_RUN=false
FORCE_ROTATION=false
SKIP_VALIDATION=false
CERT_TYPE="all"
NODE_NAME=$(hostname)
BACKUP_TIMESTAMP=""
ROTATED_CERTS=()

# Certificate types (using portable approach instead of associative arrays)
# These are handled by kubeadm certs renew command

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
                \"service\": \"cert-rotation\",
                \"message\": \"$message\",
                \"severity\": \"$severity\",
                \"timestamp\": \"$(date -Iseconds)\",
                \"hostname\": \"$(hostname)\",
                \"node\": \"$NODE_NAME\"
            }" 2>/dev/null || log_warn "Failed to send alert"
    fi
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v kubeadm >/dev/null 2>&1; then
        missing_deps+=("kubeadm")
    fi
    
    if ! command -v kubectl >/dev/null 2>&1; then
        missing_deps+=("kubectl")
    fi
    
    if ! command -v openssl >/dev/null 2>&1; then
        missing_deps+=("openssl")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi
    
    # Check if we're on a control plane node
    if [[ ! -d "$KUBE_PKI_DIR" ]]; then
        log_error "Kubernetes PKI directory not found: $KUBE_PKI_DIR"
        log_error "This script must be run on a Kubernetes control plane node"
        return 1
    fi
    
    log_success "Dependencies check passed"
}

check_cert_expiry() {
    local cert_file="$1"
    local days_threshold="${2:-30}"
    
    if [[ ! -f "$cert_file" ]]; then
        log_error "Certificate file not found: $cert_file"
        return 1
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
    
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null)
    
    local current_epoch
    current_epoch=$(date +%s)
    
    local days_remaining
    days_remaining=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    if [[ $days_remaining -lt $days_threshold ]]; then
        log_warn "Certificate $cert_file expires in $days_remaining days (threshold: $days_threshold)"
        return 0
    else
        log_info "Certificate $cert_file expires in $days_remaining days"
        return 1
    fi
}

check_all_cert_expiry() {
    local days_threshold="${1:-30}"
    
    log_info "Checking certificate expiry (threshold: $days_threshold days)..."
    
    local certs_need_rotation=()
    
    # Check kubeadm managed certificates
    while IFS= read -r cert_info; do
        local cert_name cert_file days_left
        read -r cert_name cert_file days_left <<< "$cert_info"
        
        if [[ "$days_left" =~ ^[0-9]+$ ]] && (( days_left < days_threshold )); then
            certs_need_rotation+=("$cert_name")
            log_warn "$cert_name expires in $days_left days"
        fi
    done < <(kubeadm certs check-expiration 2>/dev/null | grep -E "^[a-z-]+.*[0-9]+d" | awk '{print $1, $2, $NF}' | sed 's/d$//')
    
    if [[ ${#certs_need_rotation[@]} -gt 0 ]]; then
        log_warn "${#certs_need_rotation[@]} certificate(s) need rotation: ${certs_need_rotation[*]}"
        return 0
    else
        log_success "All certificates are valid for at least $days_threshold days"
        return 1
    fi
}

create_cert_backup() {
    local backup_name="${1:-cert-backup-$(date +%Y%m%d_%H%M%S)}"
    
    if [[ "$BACKUP_CERTS" != "true" ]]; then
        log_info "Certificate backup disabled, skipping..."
        return 0
    fi
    
    log_info "Creating certificate backup: $backup_name"
    
    BACKUP_TIMESTAMP="$backup_name"
    local backup_path="$CERT_BACKUP_DIR/$backup_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create backup at: $backup_path"
        return 0
    fi
    
    # Create backup directory
    mkdir -p "$backup_path"
    
    # Backup PKI directory
    if ! cp -r "$KUBE_PKI_DIR" "$backup_path/pki"; then
        log_error "Failed to backup PKI directory"
        return 1
    fi
    
    # Backup kubeconfig files
    local kubeconfig_dirs=("/etc/kubernetes" "$HOME/.kube")
    
    for config_dir in "${kubeconfig_dirs[@]}"; do
        if [[ -d "$config_dir" ]]; then
            mkdir -p "$backup_path/configs/$(basename "$config_dir")"
            find "$config_dir" -name "*.conf" -o -name "config" | \
            while read -r config_file; do
                cp "$config_file" "$backup_path/configs/$(basename "$config_dir")/" 2>/dev/null || true
            done
        fi
    done
    
    # Create backup manifest
    cat > "$backup_path/backup-info.txt" <<EOF
Backup created: $(date)
Node: $NODE_NAME
Kubernetes version: $(kubectl version --client --short 2>/dev/null || echo "unknown")
Kubeadm version: $(kubeadm version -o short 2>/dev/null || echo "unknown")
Backup type: Certificate rotation backup
Original PKI path: $KUBE_PKI_DIR
EOF
    
    log_success "Certificate backup created: $backup_path"
}

rotate_certificates() {
    local cert_types="$1"
    
    log_info "Starting certificate rotation for: $cert_types"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would rotate certificates: $cert_types"
        return 0
    fi
    
    local rotation_cmd="kubeadm certs renew"
    
    # Determine which certificates to rotate
    if [[ "$cert_types" == "all" ]]; then
        rotation_cmd+=" all"
        log_info "Rotating all certificates"
    else
        # Split cert types and add each one
        IFS=',' read -ra CERT_ARRAY <<< "$cert_types"
        for cert in "${CERT_ARRAY[@]}"; do
            cert=$(echo "$cert" | xargs)  # trim whitespace
            rotation_cmd+=" $cert"
        done
        log_info "Rotating specific certificates: ${CERT_ARRAY[*]}"
    fi
    
    log_info "Executing: $rotation_cmd"
    
    # Capture both stdout and stderr
    local rotation_output
    if rotation_output=$(eval "$rotation_cmd" 2>&1); then
        log_success "Certificate rotation completed successfully"
        log_info "Rotation output: $rotation_output"
        
        # Parse rotated certificates from output
        while IFS= read -r line; do
            if [[ "$line" =~ certificate.*(renewed|rotated) ]]; then
                local cert_name
                cert_name=$(echo "$line" | awk '{print $1}' | sed 's/certificate//')
                ROTATED_CERTS+=("$cert_name")
            fi
        done <<< "$rotation_output"
        
        return 0
    else
        log_error "Certificate rotation failed: $rotation_output"
        send_alert "Certificate rotation failed on $NODE_NAME" "critical"
        return 1
    fi
}

update_kubeconfigs() {
    log_info "Updating kubeconfig files..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update kubeconfig files"
        return 0
    fi
    
    local kubeconfig_files=(
        "admin.conf"
        "controller-manager.conf" 
        "scheduler.conf"
        "kubelet.conf"
    )
    
    local success_count=0
    
    for config_file in "${kubeconfig_files[@]}"; do
        local config_path="/etc/kubernetes/$config_file"
        
        if [[ -f "$config_path" ]]; then
            log_info "Updating $config_file..."
            
            # Use kubeadm to regenerate the kubeconfig
            local config_type
            config_type=$(echo "$config_file" | sed 's/.conf$//')
            
            if kubeadm init phase kubeconfig "$config_type" --kubeconfig-dir /etc/kubernetes 2>/dev/null; then
                log_success "Successfully updated $config_file"
                ((success_count++))
            else
                log_warn "Failed to update $config_file using kubeadm, trying alternative method"
                
                # Alternative: copy admin.conf for other configs (not recommended for production)
                if [[ "$config_type" != "admin" ]] && [[ -f "/etc/kubernetes/admin.conf" ]]; then
                    cp "/etc/kubernetes/admin.conf" "$config_path"
                    log_warn "Copied admin.conf to $config_file (temporary measure)"
                    ((success_count++))
                fi
            fi
        else
            log_warn "Kubeconfig file not found: $config_path"
        fi
    done
    
    if [[ $success_count -gt 0 ]]; then
        log_success "Updated $success_count kubeconfig file(s)"
        return 0
    else
        log_error "Failed to update any kubeconfig files"
        return 1
    fi
}

restart_kubernetes_components() {
    if [[ "$RESTART_COMPONENTS" != "true" ]]; then
        log_info "Component restart disabled, skipping..."
        return 0
    fi
    
    log_info "Restarting Kubernetes components..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restart Kubernetes components"
        return 0
    fi
    
    local components=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd")
    local restart_success=true
    
    for component in "${components[@]}"; do
        log_info "Restarting $component..."
        
        # First try to restart via systemd (for services)
        if systemctl is-active --quiet "$component" 2>/dev/null; then
            if systemctl restart "$component"; then
                log_success "Restarted $component via systemd"
                continue
            fi
        fi
        
        # For static pods, we need to temporarily move the manifest
        local manifest_path="/etc/kubernetes/manifests/$component.yaml"
        
        if [[ -f "$manifest_path" ]]; then
            log_info "Restarting static pod: $component"
            
            # Move manifest temporarily to trigger pod recreation
            mv "$manifest_path" "${manifest_path}.tmp"
            sleep 10
            mv "${manifest_path}.tmp" "$manifest_path"
            
            # Wait for pod to be ready
            local wait_count=0
            while (( wait_count < 30 )); do
                if kubectl get pods -n kube-system -l component="$component" \
                   --field-selector=status.phase=Running >/dev/null 2>&1; then
                    log_success "Static pod $component is running"
                    break
                fi
                sleep 5
                ((wait_count++))
            done
            
            if (( wait_count >= 30 )); then
                log_error "Timeout waiting for $component to start"
                restart_success=false
            fi
        else
            log_warn "No restart method found for $component"
        fi
    done
    
    if [[ "$restart_success" == "true" ]]; then
        log_success "All components restarted successfully"
        return 0
    else
        log_error "Some components failed to restart"
        return 1
    fi
}

validate_certificates() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        log_info "Certificate validation disabled, skipping..."
        return 0
    fi
    
    log_info "Validating rotated certificates..."
    
    local validation_success=true
    
    # Check certificate expiry dates
    log_info "Checking certificate expiry dates..."
    if ! kubeadm certs check-expiration >/dev/null 2>&1; then
        log_error "Certificate expiry check failed"
        validation_success=false
    else
        log_success "Certificate expiry validation passed"
    fi
    
    # Test cluster connectivity
    log_info "Testing cluster connectivity..."
    if kubectl cluster-info >/dev/null 2>&1; then
        log_success "Cluster connectivity test passed"
    else
        log_error "Cluster connectivity test failed"
        validation_success=false
    fi
    
    # Test node status
    log_info "Checking node status..."
    local node_status
    node_status=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    
    if [[ "$node_status" == "True" ]]; then
        log_success "Node status validation passed"
    else
        log_error "Node status validation failed: $node_status"
        validation_success=false
    fi
    
    # Test API server
    log_info "Testing API server health..."
    if kubectl get --raw '/healthz' >/dev/null 2>&1; then
        log_success "API server health check passed"
    else
        log_error "API server health check failed"
        validation_success=false
    fi
    
    if [[ "$validation_success" == "true" ]]; then
        log_success "Certificate validation completed successfully"
        return 0
    else
        log_error "Certificate validation failed"
        return 1
    fi
}

rollback_certificates() {
    local backup_name="$1"
    
    if [[ -z "$backup_name" ]]; then
        log_error "No backup specified for rollback"
        return 1
    fi
    
    local backup_path="$CERT_BACKUP_DIR/$backup_name"
    
    if [[ ! -d "$backup_path" ]]; then
        log_error "Backup directory not found: $backup_path"
        return 1
    fi
    
    log_warn "Rolling back certificates from backup: $backup_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would rollback from: $backup_path"
        return 0
    fi
    
    # Stop components before rollback
    log_info "Stopping Kubernetes components for rollback..."
    local components=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd")
    
    for component in "${components[@]}"; do
        local manifest_path="/etc/kubernetes/manifests/$component.yaml"
        if [[ -f "$manifest_path" ]]; then
            mv "$manifest_path" "${manifest_path}.backup"
        fi
    done
    
    sleep 10
    
    # Restore PKI directory
    if [[ -d "$backup_path/pki" ]]; then
        log_info "Restoring PKI directory..."
        rm -rf "${KUBE_PKI_DIR}.rollback" 2>/dev/null || true
        mv "$KUBE_PKI_DIR" "${KUBE_PKI_DIR}.rollback"
        cp -r "$backup_path/pki" "$KUBE_PKI_DIR"
        log_success "PKI directory restored"
    fi
    
    # Restore kubeconfig files
    if [[ -d "$backup_path/configs" ]]; then
        log_info "Restoring kubeconfig files..."
        find "$backup_path/configs" -name "*.conf" -o -name "config" | \
        while read -r config_file; do
            local target_path
            if [[ "$config_file" =~ /kubernetes/ ]]; then
                target_path="/etc/kubernetes/$(basename "$config_file")"
            else
                target_path="$HOME/.kube/$(basename "$config_file")"
            fi
            cp "$config_file" "$target_path" 2>/dev/null || true
        done
        log_success "Kubeconfig files restored"
    fi
    
    # Restart components
    log_info "Restarting Kubernetes components after rollback..."
    for component in "${components[@]}"; do
        local manifest_path="/etc/kubernetes/manifests/$component.yaml"
        if [[ -f "${manifest_path}.backup" ]]; then
            mv "${manifest_path}.backup" "$manifest_path"
        fi
    done
    
    # Wait for components to start
    sleep 30
    
    # Validate rollback
    if kubectl cluster-info >/dev/null 2>&1; then
        log_success "Rollback completed successfully"
        send_alert "Certificate rollback completed on $NODE_NAME" "warning"
        return 0
    else
        log_error "Rollback validation failed"
        send_alert "Certificate rollback failed on $NODE_NAME" "critical"
        return 1
    fi
}

generate_rotation_report() {
    local start_time="$1"
    local end_time="$2"
    local success="$3"
    
    local duration
    duration=$((end_time - start_time))
    
    cat <<EOF

========================
CERTIFICATE ROTATION REPORT
========================
Node: $NODE_NAME
Start Time: $(date -d @"$start_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$start_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
End Time: $(date -d @"$end_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$end_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
Duration: ${duration}s
Certificate Type: $CERT_TYPE
Rotated Certificates: ${ROTATED_CERTS[*]:-none}
Backup Created: $BACKUP_TIMESTAMP
Success: $success
Dry Run: $DRY_RUN
========================

EOF
}

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Rotate Kubernetes certificates safely with backup and validation.

Options:
  -h, --help              Show this help message
  -t, --type TYPE        Certificate type to rotate (default: all)
                         Options: all, apiserver, apiserver-kubelet-client,
                         front-proxy-client, etcd-server, etcd-peer, etc.
  --dry-run              Show what would be done without executing
  --force                Force rotation ignoring expiry checks
  --skip-validation      Skip post-rotation validation
  --no-backup            Skip certificate backup
  --no-restart           Skip component restart
  --rollback BACKUP      Rollback to specified backup
  --list-backups         List available certificate backups
  --check-expiry DAYS    Check certificate expiry (default: 30 days)
  --backup-only          Only create backup, don't rotate

Environment Variables:
  CERT_BACKUP_DIR        Certificate backup directory
  KUBE_PKI_DIR          Kubernetes PKI directory
  ROTATION_TIMEOUT      Rotation timeout in seconds
  VALIDATION_TIMEOUT    Validation timeout in seconds
  RESTART_COMPONENTS    Restart components after rotation (true/false)
  BACKUP_CERTS          Create backup before rotation (true/false)
  ALERT_WEBHOOK         Webhook URL for alerts
  LOG_FILE              Log file path

Examples:
  $0                                    # Rotate all certificates
  $0 --dry-run                         # Show what would be rotated
  $0 --type apiserver                  # Rotate only API server certificates
  $0 --check-expiry 7                  # Check for certificates expiring in 7 days
  $0 --rollback cert-backup-20240101   # Rollback to specific backup
  $0 --backup-only                     # Create backup without rotation
EOF
}

main() {
    local start_time end_time success="false"
    start_time=$(date +%s)
    
    log_info "Starting certificate rotation operation (PID: $$)"
    log_info "Node: $NODE_NAME, Certificate Type: $CERT_TYPE, Dry Run: $DRY_RUN"
    
    # Create log and backup directories
    mkdir -p "$(dirname "$LOG_FILE")"
    mkdir -p "$CERT_BACKUP_DIR"
    
    # Check prerequisites
    if ! check_dependencies; then
        exit 1
    fi
    
    # Handle special operations
    if [[ "$CHECK_EXPIRY_ONLY" == "true" ]]; then
        check_all_cert_expiry "$EXPIRY_DAYS"
        exit $?
    fi
    
    if [[ "$LIST_BACKUPS" == "true" ]]; then
        log_info "Available certificate backups:"
        ls -la "$CERT_BACKUP_DIR" 2>/dev/null || log_info "No backups found"
        exit 0
    fi
    
    if [[ "$ROLLBACK_BACKUP" != "" ]]; then
        if rollback_certificates "$ROLLBACK_BACKUP"; then
            success="true"
        fi
        end_time=$(date +%s)
        generate_rotation_report "$start_time" "$end_time" "$success" | tee -a "$LOG_FILE"
        exit $([ "$success" == "true" ] && echo 0 || echo 1)
    fi
    
    # Check if rotation is needed (unless forced)
    if [[ "$FORCE_ROTATION" != "true" ]] && [[ "$BACKUP_ONLY" != "true" ]]; then
        if ! check_all_cert_expiry 30; then
            log_info "No certificates need rotation at this time"
            if [[ "$DRY_RUN" != "true" ]]; then
                exit 0
            fi
        fi
    fi
    
    # Create backup
    if ! create_cert_backup; then
        log_error "Failed to create certificate backup"
        exit 1
    fi
    
    if [[ "$BACKUP_ONLY" == "true" ]]; then
        log_success "Backup-only operation completed"
        exit 0
    fi
    
    # Rotate certificates
    if ! rotate_certificates "$CERT_TYPE"; then
        log_error "Certificate rotation failed"
        if [[ "$BACKUP_TIMESTAMP" != "" ]]; then
            log_warn "Consider rolling back with: $0 --rollback $BACKUP_TIMESTAMP"
        fi
        exit 1
    fi
    
    # Update kubeconfig files
    if ! update_kubeconfigs; then
        log_warn "Failed to update kubeconfig files, cluster may be unstable"
    fi
    
    # Restart components
    if ! restart_kubernetes_components; then
        log_warn "Failed to restart some components, manual intervention may be required"
    fi
    
    # Validate certificates
    if validate_certificates; then
        success="true"
        log_success "Certificate rotation completed successfully"
        send_alert "Certificate rotation completed successfully on $NODE_NAME" "info"
    else
        log_error "Certificate validation failed after rotation"
        send_alert "Certificate rotation validation failed on $NODE_NAME" "critical"
        
        if [[ "$BACKUP_TIMESTAMP" != "" ]]; then
            log_warn "Consider rolling back with: $0 --rollback $BACKUP_TIMESTAMP"
        fi
    fi
    
    end_time=$(date +%s)
    
    # Generate report
    generate_rotation_report "$start_time" "$end_time" "$success" | tee -a "$LOG_FILE"
    
    exit $([ "$success" == "true" ] && echo 0 || echo 1)
}

# Initialize variables for argument parsing
CHECK_EXPIRY_ONLY=false
LIST_BACKUPS=false
ROLLBACK_BACKUP=""
BACKUP_ONLY=false
EXPIRY_DAYS=30

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -t|--type)
            if [[ -z "${2:-}" ]]; then
                log_error "--type requires a value"
                exit 1
            fi
            CERT_TYPE="$2"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --force)
            FORCE_ROTATION=true
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            ;;
        --no-backup)
            BACKUP_CERTS=false
            ;;
        --no-restart)
            RESTART_COMPONENTS=false
            ;;
        --rollback)
            if [[ -z "${2:-}" ]]; then
                log_error "--rollback requires a backup name"
                exit 1
            fi
            ROLLBACK_BACKUP="$2"
            shift
            ;;
        --list-backups)
            LIST_BACKUPS=true
            ;;
        --check-expiry)
            if [[ -z "${2:-}" ]]; then
                log_error "--check-expiry requires a number of days"
                exit 1
            fi
            EXPIRY_DAYS="$2"
            CHECK_EXPIRY_ONLY=true
            shift
            ;;
        --backup-only)
            BACKUP_ONLY=true
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            log_error "Unexpected argument: $1"
            show_usage
            exit 1
            ;;
    esac
    shift
done

# Handle signals gracefully
trap 'log_info "Certificate rotation interrupted"; exit 130' SIGINT SIGTERM

# Run main function
main "$@"
