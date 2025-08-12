#!/bin/bash
# Comprehensive Node Drain Script for Kubernetes Maintenance
# Safely drains nodes with configurable options and validation

set -euo pipefail

# Configuration
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300}"  # 5 minutes default
GRACE_PERIOD="${GRACE_PERIOD:-30}"     # 30 seconds default
DELETE_LOCAL_DATA="${DELETE_LOCAL_DATA:-false}"
IGNORE_DAEMONSETS="${IGNORE_DAEMONSETS:-true}"
FORCE_DRAIN="${FORCE_DRAIN:-false}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
LOG_FILE="${LOG_FILE:-/var/log/node-drain.log}"
KUBECONFIG="${KUBECONFIG:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
NODE_NAME=""
DRY_RUN=false
SKIP_VALIDATION=false
WAIT_FOR_PODS=true
CORDON_ONLY=false
UNCORDON=false

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
                \"service\": \"node-drain\",
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
    
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl not found in PATH"
        return 1
    fi
    
    # Test kubectl connection
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    log_success "Dependencies check passed"
}

validate_node() {
    local node="$1"
    
    log_info "Validating node: $node"
    
    # Check if node exists
    if ! kubectl get node "$node" >/dev/null 2>&1; then
        log_error "Node '$node' not found in cluster"
        return 1
    fi
    
    # Check if node is already cordoned
    local node_status
    node_status=$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
    
    if [[ "$node_status" == "true" ]]; then
        log_warn "Node '$node' is already cordoned"
    fi
    
    # Check node role and conditions
    local node_roles
    node_roles=$(kubectl get node "$node" -o jsonpath='{.metadata.labels}' | \
                grep -o 'node-role\.kubernetes\.io/[^"]*' | cut -d/ -f2 || echo "worker")
    
    log_info "Node '$node' roles: $node_roles"
    
    # Warn if draining master node
    if echo "$node_roles" | grep -q "control-plane\|master"; then
        log_warn "WARNING: Attempting to drain control-plane node '$node'"
        if [[ "$FORCE_DRAIN" != "true" ]]; then
            log_error "Use --force to drain control-plane nodes"
            return 1
        fi
    fi
    
    log_success "Node validation passed"
}

get_node_pods() {
    local node="$1"
    local namespace_filter="${2:-}"
    
    local kubectl_cmd="kubectl get pods --all-namespaces --field-selector=spec.nodeName=$node"
    
    if [[ -n "$namespace_filter" ]]; then
        kubectl_cmd="kubectl get pods -n $namespace_filter --field-selector=spec.nodeName=$node"
    fi
    
    $kubectl_cmd --no-headers -o custom-columns=":metadata.namespace,:metadata.name,:status.phase" 2>/dev/null
}

check_critical_pods() {
    local node="$1"
    
    log_info "Checking for critical pods on node '$node'..."
    
    # Get all pods on the node
    local pods_on_node
    pods_on_node=$(get_node_pods "$node")
    
    if [[ -z "$pods_on_node" ]]; then
        log_info "No pods found on node '$node'"
        return 0
    fi
    
    local critical_pods=()
    
    # Check for system critical pods
    while IFS= read -r pod_line; do
        local namespace pod_name phase
        read -r namespace pod_name phase <<< "$pod_line"
        
        # Skip empty lines
        [[ -z "$namespace" ]] && continue
        
        # Check for critical system namespaces
        if [[ "$namespace" =~ ^(kube-system|kube-public|kubernetes-dashboard)$ ]]; then
            # Check if it's a DaemonSet pod
            local owner_kind
            owner_kind=$(kubectl get pod "$pod_name" -n "$namespace" \
                        -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
            
            if [[ "$owner_kind" != "DaemonSet" ]] || [[ "$IGNORE_DAEMONSETS" != "true" ]]; then
                critical_pods+=("$namespace/$pod_name")
            fi
        fi
        
        # Check for pods with critical annotations
        local critical_annotation
        critical_annotation=$(kubectl get pod "$pod_name" -n "$namespace" \
                             -o jsonpath='{.metadata.annotations.scheduler\.alpha\.kubernetes\.io/critical-pod}' 2>/dev/null || echo "")
        
        if [[ "$critical_annotation" == "true" ]]; then
            critical_pods+=("$namespace/$pod_name")
        fi
    done <<< "$pods_on_node"
    
    if [[ ${#critical_pods[@]} -gt 0 ]]; then
        log_warn "Found ${#critical_pods[@]} critical pod(s) on node '$node':"
        for pod in "${critical_pods[@]}"; do
            log_warn "  - $pod"
        done
        
        if [[ "$FORCE_DRAIN" != "true" ]]; then
            log_error "Use --force to drain nodes with critical pods"
            return 1
        fi
    fi
    
    log_info "Critical pods check completed"
}

cordon_node() {
    local node="$1"
    
    log_info "Cordoning node '$node'..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would cordon node '$node'"
        return 0
    fi
    
    if ! kubectl cordon "$node"; then
        log_error "Failed to cordon node '$node'"
        send_alert "Failed to cordon node $node" "critical"
        return 1
    fi
    
    log_success "Node '$node' successfully cordoned"
}

uncordon_node() {
    local node="$1"
    
    log_info "Uncordoning node '$node'..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would uncordon node '$node'"
        return 0
    fi
    
    if ! kubectl uncordon "$node"; then
        log_error "Failed to uncordon node '$node'"
        send_alert "Failed to uncordon node $node" "warning"
        return 1
    fi
    
    log_success "Node '$node' successfully uncordoned"
}

drain_node() {
    local node="$1"
    
    log_info "Starting drain of node '$node'..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would drain node '$node'"
        return 0
    fi
    
    # Build kubectl drain command
    local drain_cmd="kubectl drain $node --timeout=${DRAIN_TIMEOUT}s --grace-period=$GRACE_PERIOD"
    
    if [[ "$DELETE_LOCAL_DATA" == "true" ]]; then
        drain_cmd+=" --delete-emptydir-data"
    fi
    
    if [[ "$IGNORE_DAEMONSETS" == "true" ]]; then
        drain_cmd+=" --ignore-daemonsets"
    fi
    
    if [[ "$FORCE_DRAIN" == "true" ]]; then
        drain_cmd+=" --force"
    fi
    
    log_info "Executing: $drain_cmd"
    
    if ! eval "$drain_cmd"; then
        log_error "Failed to drain node '$node'"
        send_alert "Failed to drain node $node" "critical"
        return 1
    fi
    
    log_success "Node '$node' successfully drained"
}

wait_for_pods_eviction() {
    local node="$1"
    local max_wait="${2:-300}"  # 5 minutes default
    
    if [[ "$WAIT_FOR_PODS" != "true" ]] || [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi
    
    log_info "Waiting for pods to be evicted from node '$node' (max wait: ${max_wait}s)..."
    
    local elapsed=0
    local check_interval=10
    
    while (( elapsed < max_wait )); do
        local remaining_pods
        remaining_pods=$(get_node_pods "$node" | wc -l)
        
        # Filter out DaemonSet pods if ignoring them
        if [[ "$IGNORE_DAEMONSETS" == "true" ]]; then
            local non_daemonset_pods=0
            while IFS= read -r pod_line; do
                [[ -z "$pod_line" ]] && continue
                local namespace pod_name
                read -r namespace pod_name _ <<< "$pod_line"
                
                local owner_kind
                owner_kind=$(kubectl get pod "$pod_name" -n "$namespace" \
                            -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
                
                if [[ "$owner_kind" != "DaemonSet" ]]; then
                    ((non_daemonset_pods++))
                fi
            done <<< "$(get_node_pods "$node")"
            
            remaining_pods=$non_daemonset_pods
        fi
        
        if [[ "$remaining_pods" -eq 0 ]]; then
            log_success "All pods successfully evicted from node '$node'"
            return 0
        fi
        
        log_info "$remaining_pods pods still running on node '$node', waiting..."
        sleep $check_interval
        ((elapsed += check_interval))
    done
    
    log_warn "Timeout waiting for pod eviction from node '$node' (${remaining_pods} pods remain)"
    return 1
}

generate_drain_report() {
    local node="$1"
    local start_time="$2"
    local end_time="$3"
    
    local duration
    duration=$(( end_time - start_time ))
    
    local node_info
    node_info=$(kubectl get node "$node" -o custom-columns=":metadata.name,:status.conditions[?(@.type=='Ready')].status,:spec.unschedulable" --no-headers 2>/dev/null || echo "$node Unknown Unknown")
    
    local remaining_pods
    remaining_pods=$(get_node_pods "$node" | wc -l)
    
    cat <<EOF

========================
NODE DRAIN REPORT
========================
Node: $node
Operation: $([ "$UNCORDON" == "true" ] && echo "Uncordon" || echo "Drain")
Start Time: $(date -d @"$start_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$start_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
End Time: $(date -d @"$end_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$end_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
Duration: ${duration}s
Node Info: $node_info
Remaining Pods: $remaining_pods
Dry Run: $DRY_RUN
========================

EOF
}

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] NODE_NAME

Drain a Kubernetes node for maintenance.

Options:
  -h, --help              Show this help message
  -n, --dry-run          Show what would be done without executing
  -f, --force            Force drain (ignore warnings)
  -c, --cordon-only      Only cordon the node, don't drain
  -u, --uncordon         Uncordon the node instead of draining
  --skip-validation      Skip node validation checks
  --no-wait             Don't wait for pod eviction to complete
  --timeout SECONDS     Drain timeout (default: $DRAIN_TIMEOUT)
  --grace-period SECONDS Grace period for pod termination (default: $GRACE_PERIOD)
  --delete-local-data   Allow deletion of pods with local data
  --no-ignore-daemonsets Don't ignore DaemonSet pods

Environment Variables:
  DRAIN_TIMEOUT         Drain operation timeout in seconds
  GRACE_PERIOD         Pod termination grace period
  DELETE_LOCAL_DATA    Allow deletion of local data (true/false)
  IGNORE_DAEMONSETS    Ignore DaemonSet pods (true/false) 
  FORCE_DRAIN          Force drain operation (true/false)
  ALERT_WEBHOOK        Webhook URL for alerts
  LOG_FILE             Log file path
  KUBECONFIG           Kubernetes config file path

Examples:
  $0 worker-node-1                    # Drain worker-node-1
  $0 --dry-run master-node-1          # Show what would happen
  $0 --force --timeout 600 node-2     # Force drain with 10min timeout
  $0 --uncordon worker-node-1         # Uncordon node
  $0 --cordon-only worker-node-2      # Only cordon node
EOF
}

main() {
    local start_time end_time
    start_time=$(date +%s)
    
    log_info "Starting node drain operation (PID: $$)"
    log_info "Node: $NODE_NAME, Dry Run: $DRY_RUN, Uncordon: $UNCORDON"
    
    # Create log directory
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Check prerequisites
    if ! check_dependencies; then
        exit 1
    fi
    
    # Validate node
    if [[ "$SKIP_VALIDATION" != "true" ]]; then
        if ! validate_node "$NODE_NAME"; then
            exit 1
        fi
    fi
    
    # Handle uncordon operation
    if [[ "$UNCORDON" == "true" ]]; then
        if ! uncordon_node "$NODE_NAME"; then
            exit 1
        fi
    else
        # Check for critical pods
        if [[ "$SKIP_VALIDATION" != "true" ]]; then
            check_critical_pods "$NODE_NAME" || exit 1
        fi
        
        # Cordon the node
        if ! cordon_node "$NODE_NAME"; then
            exit 1
        fi
        
        # Drain the node (unless cordon-only)
        if [[ "$CORDON_ONLY" != "true" ]]; then
            if ! drain_node "$NODE_NAME"; then
                exit 1
            fi
            
            # Wait for pod eviction
            wait_for_pods_eviction "$NODE_NAME" "$DRAIN_TIMEOUT"
        fi
    fi
    
    end_time=$(date +%s)
    
    # Generate report
    generate_drain_report "$NODE_NAME" "$start_time" "$end_time" | tee -a "$LOG_FILE"
    
    log_success "Node drain operation completed successfully"
    send_alert "Node $NODE_NAME drain operation completed" "info"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -n|--dry-run)
            DRY_RUN=true
            ;;
        -f|--force)
            FORCE_DRAIN=true
            ;;
        -c|--cordon-only)
            CORDON_ONLY=true
            ;;
        -u|--uncordon)
            UNCORDON=true
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            ;;
        --no-wait)
            WAIT_FOR_PODS=false
            ;;
        --timeout)
            if [[ -z "${2:-}" ]]; then
                log_error "--timeout requires a value"
                exit 1
            fi
            DRAIN_TIMEOUT="$2"
            shift
            ;;
        --grace-period)
            if [[ -z "${2:-}" ]]; then
                log_error "--grace-period requires a value"
                exit 1
            fi
            GRACE_PERIOD="$2"
            shift
            ;;
        --delete-local-data)
            DELETE_LOCAL_DATA=true
            ;;
        --no-ignore-daemonsets)
            IGNORE_DAEMONSETS=false
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [[ -n "$NODE_NAME" ]]; then
                log_error "Multiple node names specified: '$NODE_NAME' and '$1'"
                exit 1
            fi
            NODE_NAME="$1"
            ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$NODE_NAME" ]]; then
    log_error "Node name is required"
    show_usage
    exit 1
fi

# Handle signals gracefully
trap 'log_info "Node drain interrupted"; exit 130' SIGINT SIGTERM

# Run main function
main "$@"
