#!/bin/bash
# Comprehensive Infrastructure Health Check Script
# Monitors system health, Kubernetes cluster status, and application health

set -euo pipefail

# Configuration
LOG_FILE="${LOG_FILE:-/var/log/romulus-health-check.log}"
METRICS_FILE="${METRICS_FILE:-/tmp/health-metrics.json}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
MAX_FAILURES="${MAX_FAILURES:-3}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Initialize counters file (using file-based approach for portability)
FAILURE_COUNTS_FILE="/tmp/romulus-failure-counts.txt"
touch "$FAILURE_COUNTS_FILE"

get_failure_count() {
    local check="$1"
    grep "^${check}:" "$FAILURE_COUNTS_FILE" 2>/dev/null | cut -d: -f2 || echo "0"
}

set_failure_count() {
    local check="$1"
    local count="$2"
    
    # Remove existing entry and add new one
    grep -v "^${check}:" "$FAILURE_COUNTS_FILE" 2>/dev/null > "${FAILURE_COUNTS_FILE}.tmp" || touch "${FAILURE_COUNTS_FILE}.tmp"
    echo "${check}:${count}" >> "${FAILURE_COUNTS_FILE}.tmp"
    mv "${FAILURE_COUNTS_FILE}.tmp" "$FAILURE_COUNTS_FILE"
}

increment_failure_count() {
    local check="$1"
    local current
    current=$(get_failure_count "$check")
    set_failure_count "$check" $((current + 1))
}

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
    local service="$1"
    local message="$2"
    local severity="$3"
    
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        curl -X POST "$ALERT_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{
                \"service\": \"$service\",
                \"message\": \"$message\",
                \"severity\": \"$severity\",
                \"timestamp\": \"$(date -Iseconds)\",
                \"hostname\": \"$(hostname)\"
            }" 2>/dev/null || log_warn "Failed to send alert for $service"
    fi
}

check_system_resources() {
    log_info "Checking system resources..."
    
    # CPU usage (using portable commands for macOS)
    local cpu_usage
    if command -v top >/dev/null 2>&1; then
        # macOS top command format
        cpu_usage=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | sed 's/%//' | cut -d'.' -f1 2>/dev/null || echo "0")
    else
        cpu_usage="0"
    fi
    
    if [[ "$cpu_usage" =~ ^[0-9]+$ ]] && (( cpu_usage > 90 )); then
        log_error "High CPU usage: ${cpu_usage}%"
        send_alert "system" "High CPU usage: ${cpu_usage}%" "critical"
        increment_failure_count "cpu"
    else
        log_success "CPU usage normal: ${cpu_usage}%"
        set_failure_count "cpu" 0
    fi
    
    # Memory usage
    local mem_usage
    if command -v vm_stat >/dev/null 2>&1; then
        # macOS memory calculation
        local pages_free pages_active pages_inactive pages_speculative pages_wired page_size
        pages_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//')
        pages_active=$(vm_stat | grep "Pages active" | awk '{print $3}' | sed 's/\.//')
        pages_inactive=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | sed 's/\.//')
        pages_speculative=$(vm_stat | grep "Pages speculative" | awk '{print $3}' | sed 's/\.//')
        pages_wired=$(vm_stat | grep "Pages wired down" | awk '{print $4}' | sed 's/\.//')
        page_size=$(vm_stat | grep "page size" | awk '{print $8}')
        
        local total_pages used_pages
        total_pages=$((pages_free + pages_active + pages_inactive + pages_speculative + pages_wired))
        used_pages=$((pages_active + pages_wired))
        mem_usage=$(echo "scale=1; $used_pages * 100 / $total_pages" | bc 2>/dev/null || echo "0")
    else
        mem_usage="0"
    fi
    
    if [[ "$mem_usage" != "0" ]] && (( $(echo "$mem_usage > 85" | bc -l 2>/dev/null || echo "0") )); then
        log_error "High memory usage: ${mem_usage}%"
        send_alert "system" "High memory usage: ${mem_usage}%" "warning"
        increment_failure_count "memory"
    else
        log_success "Memory usage normal: ${mem_usage}%"
        set_failure_count "memory" 0
    fi
    
    # Disk usage
    while IFS= read -r line; do
        local usage mount
        usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        mount=$(echo "$line" | awk '{print $6}')
        
        if [[ "$usage" =~ ^[0-9]+$ ]] && (( usage > 85 )); then
            log_error "High disk usage on $mount: ${usage}%"
            send_alert "system" "High disk usage on $mount: ${usage}%" "warning"
            increment_failure_count "disk_${mount//\//_}"
        else
            log_success "Disk usage normal on $mount: ${usage}%"
            set_failure_count "disk_${mount//\//_}" 0
        fi
    done < <(df -h | grep -E '^/dev/' 2>/dev/null || true)
    
    # Load average
    local load_avg
    load_avg=$(uptime | awk -F'load average[s]*:' '{print $2}' | awk '{print $1}' | sed 's/,//' 2>/dev/null || echo "0")
    local cpu_cores
    cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "1")
    
    if [[ "$load_avg" != "0" ]] && (( $(echo "$load_avg > $cpu_cores * 2" | bc -l 2>/dev/null || echo "0") )); then
        log_error "High load average: $load_avg (cores: $cpu_cores)"
        send_alert "system" "High load average: $load_avg" "warning"
        increment_failure_count "load"
    else
        log_success "Load average normal: $load_avg"
        set_failure_count "load" 0
    fi
}

check_network_connectivity() {
    log_info "Checking network connectivity..."
    
    # Check DNS resolution (skip if kubectl not available)
    if command -v kubectl >/dev/null 2>&1; then
        if nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
            log_success "DNS resolution working"
            set_failure_count "dns" 0
        else
            log_error "DNS resolution failed"
            send_alert "network" "DNS resolution failed" "critical"
            increment_failure_count "dns"
        fi
    else
        log_info "Kubernetes not available, skipping cluster DNS check"
    fi
    
    # Check internet connectivity
    if curl -s --max-time 5 https://8.8.8.8 &>/dev/null; then
        log_success "Internet connectivity working"
        set_failure_count "internet" 0
    else
        log_warn "Internet connectivity issues"
        increment_failure_count "internet"
    fi
    
    # Check internal network (only if kubectl available)
    if command -v kubectl >/dev/null 2>&1; then
        local master_nodes
        master_nodes=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers -o custom-columns=":metadata.name" 2>/dev/null || echo "")
        
        if [[ -n "$master_nodes" ]]; then
            while IFS= read -r node; do
                local node_ip
                node_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
                
                if [[ -n "$node_ip" ]] && ping -c 1 -W 2 "$node_ip" &>/dev/null; then
                    log_success "Node $node ($node_ip) is reachable"
                    set_failure_count "node_$node" 0
                else
                    log_error "Node $node ($node_ip) is unreachable"
                    send_alert "network" "Node $node unreachable" "critical"
                    increment_failure_count "node_$node"
                fi
            done <<< "$master_nodes"
        fi
    fi
}

check_kubernetes_cluster() {
    log_info "Checking Kubernetes cluster health..."
    
    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found, skipping Kubernetes checks"
        return 0
    fi
    
    # Check API server connectivity
    if kubectl cluster-info &>/dev/null; then
        log_success "Kubernetes API server is accessible"
        set_failure_count "k8s_api" 0
    else
        log_error "Cannot connect to Kubernetes API server"
        send_alert "kubernetes" "API server unreachable" "critical"
        increment_failure_count "k8s_api"
        return 1
    fi
    
    # Check node status
    local not_ready_nodes
    not_ready_nodes=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}' | wc -l)
    
    if [[ "$not_ready_nodes" -eq 0 ]]; then
        log_success "All nodes are Ready"
        set_failure_count "k8s_nodes" 0
    else
        log_error "$not_ready_nodes node(s) are not Ready"
        send_alert "kubernetes" "$not_ready_nodes nodes not ready" "critical"
        increment_failure_count "k8s_nodes"
    fi
    
    # Check system pods
    local failing_pods
    failing_pods=$(kubectl get pods -n kube-system --no-headers | awk '$3 != "Running" && $3 != "Completed" {print $1}' | wc -l)
    
    if [[ "$failing_pods" -eq 0 ]]; then
        log_success "All system pods are running"
        set_failure_count "k8s_system_pods" 0
    else
        log_error "$failing_pods system pod(s) are not running"
        send_alert "kubernetes" "$failing_pods system pods failing" "critical"
        increment_failure_count "k8s_system_pods"
    fi
    
    # Check persistent volumes
    local pv_issues
    pv_issues=$(kubectl get pv --no-headers 2>/dev/null | awk '$5 != "Bound" && $5 != "Available" {print $1}' | wc -l)
    
    if [[ "$pv_issues" -eq 0 ]]; then
        log_success "All persistent volumes are healthy"
        set_failure_count "k8s_pv" 0
    else
        log_warn "$pv_issues persistent volume(s) have issues"
        increment_failure_count "k8s_pv"
    fi
}

check_application_health() {
    log_info "Checking application health..."
    
    # Skip if kubectl not available
    if ! command -v kubectl &>/dev/null; then
        log_info "kubectl not available, skipping application checks"
        return 0
    fi
    
    # Check CS2 server pods
    local cs2_pods
    cs2_pods=$(kubectl get pods -l app=cs2-server --no-headers 2>/dev/null | wc -l)
    
    if [[ "$cs2_pods" -gt 0 ]]; then
        local running_cs2_pods
        running_cs2_pods=$(kubectl get pods -l app=cs2-server --no-headers | awk '$3 == "Running" {print $1}' | wc -l)
        
        if [[ "$running_cs2_pods" -eq "$cs2_pods" ]]; then
            log_success "All CS2 server pods are running ($running_cs2_pods/$cs2_pods)"
            set_failure_count "cs2_pods" 0
        else
            log_error "CS2 server pods issues: $running_cs2_pods/$cs2_pods running"
            send_alert "application" "CS2 server pods failing" "critical"
            increment_failure_count "cs2_pods"
        fi
    else
        log_info "No CS2 server pods found"
    fi
    
    # Check monitoring stack
    local monitoring_pods
    monitoring_pods=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print $1}' | wc -l)
    
    if [[ "$monitoring_pods" -eq 0 ]]; then
        log_success "Monitoring stack is healthy"
        set_failure_count "monitoring" 0
    else
        log_warn "$monitoring_pods monitoring pod(s) are not running"
        increment_failure_count "monitoring"
    fi
}

check_services() {
    log_info "Checking critical services..."
    
    # Skip systemd checks on macOS (uses launchctl)
    if ! command -v systemctl &>/dev/null; then
        log_info "systemctl not available (likely macOS), skipping service checks"
        return 0
    fi
    
    # Check systemd services
    local services=("kubelet" "containerd" "docker")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_success "Service $service is running"
            set_failure_count "service_$service" 0
        else
            if systemctl list-unit-files | grep -q "^$service.service"; then
                log_error "Service $service is not running"
                send_alert "services" "Service $service failed" "critical"
                increment_failure_count "service_$service"
            else
                log_info "Service $service is not installed (skipped)"
            fi
        fi
    done
}

generate_metrics() {
    log_info "Generating health metrics..."
    
    local timestamp
    timestamp=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    
    # Get system metrics (macOS compatible)
    local cpu_usage mem_usage load_avg uptime_seconds
    
    # CPU usage
    if command -v top >/dev/null 2>&1; then
        cpu_usage=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | sed 's/%//' | cut -d'.' -f1 2>/dev/null || echo "0")
    else
        cpu_usage="0"
    fi
    
    # Memory usage
    if command -v vm_stat >/dev/null 2>&1; then
        local pages_free pages_active pages_wired total_pages used_pages
        pages_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//' 2>/dev/null || echo "0")
        pages_active=$(vm_stat | grep "Pages active" | awk '{print $3}' | sed 's/\.//' 2>/dev/null || echo "0")
        pages_wired=$(vm_stat | grep "Pages wired down" | awk '{print $4}' | sed 's/\.//' 2>/dev/null || echo "0")
        total_pages=$((pages_free + pages_active + pages_wired + 1000))
        used_pages=$((pages_active + pages_wired))
        mem_usage=$(echo "scale=1; $used_pages * 100 / $total_pages" | bc 2>/dev/null || echo "0")
    else
        mem_usage="0"
    fi
    
    # Load average
    load_avg=$(uptime | awk -F'load average[s]*:' '{print $2}' | awk '{print $1}' | sed 's/,//' 2>/dev/null || echo "0")
    
    # Uptime
    if [[ -f /proc/uptime ]]; then
        uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
    else
        # macOS alternative - simpler approach
        local boot_time current_time
        boot_time=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | sed 's/,//' || echo "0")
        current_time=$(date +%s)
        if [[ "$boot_time" =~ ^[0-9]+$ ]] && [[ "$current_time" =~ ^[0-9]+$ ]]; then
            uptime_seconds=$((current_time - boot_time))
        else
            uptime_seconds="0"
        fi
    fi
    
    # Get Kubernetes metrics (only if kubectl available)
    local total_nodes ready_nodes total_pods running_pods
    if command -v kubectl >/dev/null 2>&1; then
        total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {print $1}' | wc -l | tr -d ' ')
        total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
        running_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | awk '$4 == "Running" {print $1}' | wc -l | tr -d ' ')
    else
        total_nodes="0"
        ready_nodes="0"
        total_pods="0"
        running_pods="0"
    fi
    
    # Generate failure counts JSON from file
    local failure_counts_json="{}"
    if [[ -f "$FAILURE_COUNTS_FILE" ]]; then
        failure_counts_json=$(awk -F: '{
            if (NR == 1) printf "{"
            else printf ","
            printf "\"%s\":%s", $1, $2
        } END {
            if (NR > 0) printf "}"
            else printf "{}"
        }' "$FAILURE_COUNTS_FILE" 2>/dev/null || echo "{}")
    fi
    
    # Create metrics JSON
    cat > "$METRICS_FILE" <<EOF
{
  "timestamp": "$timestamp",
  "hostname": "$(hostname)",
  "system": {
    "cpu_usage_percent": $cpu_usage,
    "memory_usage_percent": $mem_usage,
    "load_average": $load_avg,
    "uptime_seconds": $uptime_seconds
  },
  "kubernetes": {
    "nodes_total": $total_nodes,
    "nodes_ready": $ready_nodes,
    "pods_total": $total_pods,
    "pods_running": $running_pods
  },
  "failure_counts": $failure_counts_json
}
EOF
    
    log_success "Health metrics saved to $METRICS_FILE"
}

check_failure_thresholds() {
    log_info "Checking failure thresholds..."
    
    if [[ ! -f "$FAILURE_COUNTS_FILE" ]]; then
        return 0
    fi
    
    while IFS=: read -r check count; do
        if [[ -n "$check" && "$count" =~ ^[0-9]+$ ]] && (( count >= MAX_FAILURES )); then
            log_error "Check '$check' has failed $MAX_FAILURES consecutive times"
            send_alert "threshold" "Check '$check' exceeded failure threshold" "critical"
        fi
    done < "$FAILURE_COUNTS_FILE"
}

main() {
    log_info "Starting health check (PID: $$)"
    log_info "Configuration: interval=${CHECK_INTERVAL}s, max_failures=${MAX_FAILURES}"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"
    
    while true; do
        log_info "Running health checks..."
        
        check_system_resources
        check_network_connectivity
        check_kubernetes_cluster
        check_application_health
        check_services
        generate_metrics
        check_failure_thresholds
        
        log_info "Health check cycle completed. Sleeping for ${CHECK_INTERVAL}s..."
        sleep "$CHECK_INTERVAL"
    done
}

# Handle signals gracefully
trap 'log_info "Health check stopping..."; exit 0' SIGTERM SIGINT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
