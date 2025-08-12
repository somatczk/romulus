#!/bin/bash
# Comprehensive Rolling Update Script for Kubernetes Deployments
# Performs safe, automated rolling updates with validation and rollback capabilities

set -euo pipefail

# Configuration
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-600}"     # 10 minutes default
READINESS_TIMEOUT="${READINESS_TIMEOUT:-300}"  # 5 minutes default
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-10}"  # 10 seconds
MAX_UNAVAILABLE="${MAX_UNAVAILABLE:-25%}"
MAX_SURGE="${MAX_SURGE:-25%}"
PRE_UPDATE_CHECKS="${PRE_UPDATE_CHECKS:-true}"
POST_UPDATE_VALIDATION="${POST_UPDATE_VALIDATION:-true}"
AUTO_ROLLBACK="${AUTO_ROLLBACK:-true}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
LOG_FILE="${LOG_FILE:-/var/log/rolling-update.log}"
KUBECONFIG="${KUBECONFIG:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
RESOURCE_TYPE=""
RESOURCE_NAME=""
NAMESPACE="default"
IMAGE_NAME=""
IMAGE_TAG=""
DRY_RUN=false
SKIP_VALIDATION=false
FORCE_UPDATE=false
ROLLBACK_ONLY=false
STRATEGY="RollingUpdate"
ORIGINAL_IMAGE=""
UPDATE_START_TIME=""
ROLLOUT_REVISION=""

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
                \"service\": \"rolling-update\",
                \"message\": \"$message\",
                \"severity\": \"$severity\",
                \"timestamp\": \"$(date -Iseconds)\",
                \"hostname\": \"$(hostname)\",
                \"resource\": \"$RESOURCE_TYPE/$RESOURCE_NAME\",
                \"namespace\": \"$NAMESPACE\"
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

validate_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    
    log_info "Validating resource: $resource_type/$resource_name in namespace $namespace"
    
    # Check if resource exists
    if ! kubectl get "$resource_type" "$resource_name" -n "$namespace" >/dev/null 2>&1; then
        log_error "Resource '$resource_type/$resource_name' not found in namespace '$namespace'"
        return 1
    fi
    
    # Check if resource supports rolling updates
    case "$resource_type" in
        "deployment"|"daemonset"|"statefulset")
            log_info "Resource type '$resource_type' supports rolling updates"
            ;;
        *)
            log_error "Resource type '$resource_type' does not support rolling updates"
            return 1
            ;;
    esac
    
    # Get current strategy
    local current_strategy
    current_strategy=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" \
                      -o jsonpath='{.spec.strategy.type}' 2>/dev/null || echo "")
    
    if [[ -n "$current_strategy" && "$current_strategy" != "RollingUpdate" ]]; then
        log_warn "Current update strategy is '$current_strategy', not 'RollingUpdate'"
        if [[ "$FORCE_UPDATE" != "true" ]]; then
            log_error "Use --force to proceed with non-RollingUpdate strategy"
            return 1
        fi
    fi
    
    log_success "Resource validation passed"
}

get_current_image() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    local container_name="${4:-}"
    
    local jsonpath_query="{.spec.template.spec.containers[0].image}"
    
    # If container name is specified, find the specific container
    if [[ -n "$container_name" ]]; then
        jsonpath_query="{.spec.template.spec.containers[?(@.name=='$container_name')].image}"
    fi
    
    kubectl get "$resource_type" "$resource_name" -n "$namespace" \
           -o jsonpath="$jsonpath_query" 2>/dev/null
}

get_replica_count() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    
    kubectl get "$resource_type" "$resource_name" -n "$namespace" \
           -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1"
}

perform_pre_update_checks() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    
    if [[ "$PRE_UPDATE_CHECKS" != "true" ]]; then
        log_info "Pre-update checks disabled, skipping..."
        return 0
    fi
    
    log_info "Performing pre-update checks..."
    
    # Check if all replicas are ready
    local ready_replicas available_replicas desired_replicas
    ready_replicas=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" \
                    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    available_replicas=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" \
                        -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    desired_replicas=$(get_replica_count "$resource_type" "$resource_name" "$namespace")
    
    if [[ "$ready_replicas" != "$desired_replicas" ]] || [[ "$available_replicas" != "$desired_replicas" ]]; then
        log_warn "Not all replicas are ready: $ready_replicas/$desired_replicas ready, $available_replicas/$desired_replicas available"
        if [[ "$FORCE_UPDATE" != "true" ]]; then
            log_error "Use --force to proceed with unhealthy replicas"
            return 1
        fi
    fi
    
    # Check node resources
    local node_pressure
    node_pressure=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="MemoryPressure")].status}' 2>/dev/null | grep -c "True" || echo "0")
    
    if [[ "$node_pressure" -gt 0 ]]; then
        log_warn "$node_pressure node(s) under memory pressure"
        if [[ "$FORCE_UPDATE" != "true" ]]; then
            log_error "Use --force to proceed with node pressure"
            return 1
        fi
    fi
    
    # Check for ongoing deployments
    local ongoing_updates
    ongoing_updates=$(kubectl get deployments -n "$namespace" \
                     -o jsonpath='{.items[?(@.status.replicas!=@.status.readyReplicas)].metadata.name}' 2>/dev/null | wc -w)
    
    if [[ "$ongoing_updates" -gt 1 ]]; then
        log_warn "$ongoing_updates deployment(s) are currently updating in namespace $namespace"
    fi
    
    log_success "Pre-update checks completed"
}

update_image() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    local new_image="$4"
    local container_name="${5:-}"
    
    log_info "Updating image to: $new_image"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would update $resource_type/$resource_name image to $new_image"
        return 0
    fi
    
    # Build kubectl set image command
    local set_image_cmd="kubectl set image $resource_type/$resource_name"
    
    if [[ -n "$container_name" ]]; then
        set_image_cmd+=" $container_name=$new_image"
    else
        # Get the first container name
        local first_container
        first_container=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" \
                         -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null)
        set_image_cmd+=" $first_container=$new_image"
    fi
    
    set_image_cmd+=" -n $namespace --record"
    
    log_info "Executing: $set_image_cmd"
    
    if ! eval "$set_image_cmd"; then
        log_error "Failed to update image"
        send_alert "Failed to update image for $resource_type/$resource_name" "critical"
        return 1
    fi
    
    # Get the new revision number
    sleep 2  # Give kubernetes time to create the new revision
    ROLLOUT_REVISION=$(kubectl rollout history "$resource_type/$resource_name" -n "$namespace" \
                      --no-headers | tail -1 | awk '{print $1}' || echo "unknown")
    
    log_success "Image update initiated (revision: $ROLLOUT_REVISION)"
}

wait_for_rollout() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    local timeout="$4"
    
    log_info "Waiting for rollout to complete (timeout: ${timeout}s)..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would wait for rollout completion"
        return 0
    fi
    
    local start_time end_time
    start_time=$(date +%s)
    end_time=$((start_time + timeout))
    
    while (( $(date +%s) < end_time )); do
        # Check rollout status
        if kubectl rollout status "$resource_type/$resource_name" -n "$namespace" --timeout=30s >/dev/null 2>&1; then
            log_success "Rollout completed successfully"
            return 0
        fi
        
        # Log current status
        local ready_replicas desired_replicas
        ready_replicas=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" \
                        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired_replicas=$(get_replica_count "$resource_type" "$resource_name" "$namespace")
        
        log_info "Rollout in progress: $ready_replicas/$desired_replicas replicas ready"
        
        sleep "$HEALTH_CHECK_INTERVAL"
    done
    
    log_error "Rollout timed out after ${timeout}s"
    return 1
}

perform_post_update_validation() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    
    if [[ "$POST_UPDATE_VALIDATION" != "true" ]]; then
        log_info "Post-update validation disabled, skipping..."
        return 0
    fi
    
    log_info "Performing post-update validation..."
    
    # Check if all replicas are ready and available
    local ready_replicas available_replicas desired_replicas
    ready_replicas=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" \
                    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    available_replicas=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" \
                        -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    desired_replicas=$(get_replica_count "$resource_type" "$resource_name" "$namespace")
    
    if [[ "$ready_replicas" != "$desired_replicas" ]] || [[ "$available_replicas" != "$desired_replicas" ]]; then
        log_error "Post-update validation failed: $ready_replicas/$desired_replicas ready, $available_replicas/$desired_replicas available"
        return 1
    fi
    
    # Check pod restart counts (high restart count may indicate issues)
    local high_restart_pods
    high_restart_pods=$(kubectl get pods -n "$namespace" -l "app=$resource_name" \
                       -o jsonpath='{.items[?(@.status.containerStatuses[0].restartCount>5)].metadata.name}' 2>/dev/null | wc -w)
    
    if [[ "$high_restart_pods" -gt 0 ]]; then
        log_warn "$high_restart_pods pod(s) have high restart counts (>5)"
    fi
    
    # Verify the image was updated
    local current_image
    current_image=$(get_current_image "$resource_type" "$resource_name" "$namespace")
    
    if [[ "$current_image" != "$IMAGE_NAME:$IMAGE_TAG" ]]; then
        log_error "Image verification failed: expected $IMAGE_NAME:$IMAGE_TAG, got $current_image"
        return 1
    fi
    
    log_success "Post-update validation completed successfully"
}

perform_rollback() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    local revision="${4:-}"
    
    log_warn "Performing rollback..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would rollback $resource_type/$resource_name"
        return 0
    fi
    
    local rollback_cmd="kubectl rollout undo $resource_type/$resource_name -n $namespace"
    
    if [[ -n "$revision" && "$revision" != "unknown" ]]; then
        rollback_cmd+=" --to-revision=$revision"
    fi
    
    log_info "Executing: $rollback_cmd"
    
    if ! eval "$rollback_cmd"; then
        log_error "Failed to initiate rollback"
        send_alert "Failed to rollback $resource_type/$resource_name" "critical"
        return 1
    fi
    
    # Wait for rollback to complete
    if wait_for_rollout "$resource_type" "$resource_name" "$namespace" "$UPDATE_TIMEOUT"; then
        log_success "Rollback completed successfully"
        send_alert "Rollback completed for $resource_type/$resource_name" "warning"
        return 0
    else
        log_error "Rollback failed or timed out"
        send_alert "Rollback failed for $resource_type/$resource_name" "critical"
        return 1
    fi
}

get_rollout_history() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    
    kubectl rollout history "$resource_type/$resource_name" -n "$namespace" 2>/dev/null
}

generate_update_report() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    local start_time="$4"
    local end_time="$5"
    local success="$6"
    
    local duration
    duration=$((end_time - start_time))
    
    local current_image
    current_image=$(get_current_image "$resource_type" "$resource_name" "$namespace")
    
    local replica_info
    replica_info=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" \
                  -o custom-columns=":spec.replicas,:status.readyReplicas,:status.availableReplicas" --no-headers 2>/dev/null)
    
    cat <<EOF

========================
ROLLING UPDATE REPORT
========================
Resource: $resource_type/$resource_name
Namespace: $namespace
Original Image: $ORIGINAL_IMAGE
Target Image: $IMAGE_NAME:$IMAGE_TAG
Current Image: $current_image
Start Time: $(date -d @"$start_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$start_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
End Time: $(date -d @"$end_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$end_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
Duration: ${duration}s
Revision: $ROLLOUT_REVISION
Replicas (Desired/Ready/Available): $replica_info
Success: $success
Dry Run: $DRY_RUN
========================

EOF
}

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] RESOURCE_TYPE RESOURCE_NAME [IMAGE]

Perform rolling update on Kubernetes resources.

Arguments:
  RESOURCE_TYPE    Resource type (deployment, daemonset, statefulset)
  RESOURCE_NAME    Name of the resource to update
  IMAGE           New image (format: image:tag or registry/image:tag)

Options:
  -h, --help              Show this help message
  -n, --namespace NS      Kubernetes namespace (default: default)
  -c, --container NAME    Container name to update (default: first container)
  --dry-run              Show what would be done without executing
  --force                Force update ignoring warnings
  --rollback             Rollback to previous revision instead of updating
  --rollback-to REV      Rollback to specific revision
  --skip-validation      Skip pre and post update validation
  --no-wait             Don't wait for rollout completion
  --timeout SECONDS     Update timeout (default: $UPDATE_TIMEOUT)
  --readiness-timeout SECONDS  Readiness check timeout (default: $READINESS_TIMEOUT)
  --max-unavailable VAL Max unavailable during update (default: $MAX_UNAVAILABLE)
  --max-surge VAL       Max surge during update (default: $MAX_SURGE)

Environment Variables:
  UPDATE_TIMEOUT          Update operation timeout
  READINESS_TIMEOUT      Pod readiness timeout
  HEALTH_CHECK_INTERVAL  Health check interval
  PRE_UPDATE_CHECKS      Enable pre-update checks (true/false)
  POST_UPDATE_VALIDATION Enable post-update validation (true/false)
  AUTO_ROLLBACK          Enable automatic rollback on failure (true/false)
  ALERT_WEBHOOK          Webhook URL for alerts
  LOG_FILE               Log file path

Examples:
  $0 deployment myapp nginx:1.21                    # Update deployment
  $0 --dry-run deployment myapp nginx:1.22          # Dry run update
  $0 --rollback deployment myapp                    # Rollback deployment
  $0 -n production deployment api app:v2.1.0       # Update in production namespace
  $0 --timeout 1200 statefulset db postgres:13     # Update with custom timeout
EOF
}

main() {
    local start_time end_time success="false"
    start_time=$(date +%s)
    UPDATE_START_TIME="$start_time"
    
    log_info "Starting rolling update operation (PID: $$)"
    log_info "Resource: $RESOURCE_TYPE/$RESOURCE_NAME, Namespace: $NAMESPACE"
    
    # Create log directory
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Check prerequisites
    if ! check_dependencies; then
        exit 1
    fi
    
    # Validate resource
    if [[ "$SKIP_VALIDATION" != "true" ]]; then
        if ! validate_resource "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE"; then
            exit 1
        fi
    fi
    
    # Get original image for rollback purposes
    ORIGINAL_IMAGE=$(get_current_image "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE")
    log_info "Current image: $ORIGINAL_IMAGE"
    
    # Handle rollback operation
    if [[ "$ROLLBACK_ONLY" == "true" ]]; then
        log_info "Performing rollback operation..."
        if perform_rollback "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE" "$ROLLBACK_REVISION"; then
            success="true"
        fi
    else
        # Perform rolling update
        log_info "Target image: $IMAGE_NAME:$IMAGE_TAG"
        
        # Pre-update checks
        if ! perform_pre_update_checks "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE"; then
            exit 1
        fi
        
        # Update the image
        if ! update_image "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE" "$IMAGE_NAME:$IMAGE_TAG" "$CONTAINER_NAME"; then
            exit 1
        fi
        
        # Wait for rollout completion
        if wait_for_rollout "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE" "$UPDATE_TIMEOUT"; then
            # Post-update validation
            if perform_post_update_validation "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE"; then
                success="true"
            elif [[ "$AUTO_ROLLBACK" == "true" ]]; then
                log_warn "Post-update validation failed, initiating automatic rollback..."
                perform_rollback "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE"
            fi
        elif [[ "$AUTO_ROLLBACK" == "true" ]]; then
            log_warn "Rollout failed, initiating automatic rollback..."
            perform_rollback "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE"
        fi
    fi
    
    end_time=$(date +%s)
    
    # Generate report
    generate_update_report "$RESOURCE_TYPE" "$RESOURCE_NAME" "$NAMESPACE" "$start_time" "$end_time" "$success" | tee -a "$LOG_FILE"
    
    if [[ "$success" == "true" ]]; then
        log_success "Rolling update operation completed successfully"
        send_alert "Rolling update completed for $RESOURCE_TYPE/$RESOURCE_NAME" "info"
        exit 0
    else
        log_error "Rolling update operation failed"
        send_alert "Rolling update failed for $RESOURCE_TYPE/$RESOURCE_NAME" "critical"
        exit 1
    fi
}

# Parse command line arguments
ROLLBACK_REVISION=""
CONTAINER_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -n|--namespace)
            if [[ -z "${2:-}" ]]; then
                log_error "--namespace requires a value"
                exit 1
            fi
            NAMESPACE="$2"
            shift
            ;;
        -c|--container)
            if [[ -z "${2:-}" ]]; then
                log_error "--container requires a value"
                exit 1
            fi
            CONTAINER_NAME="$2"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --force)
            FORCE_UPDATE=true
            ;;
        --rollback)
            ROLLBACK_ONLY=true
            ;;
        --rollback-to)
            if [[ -z "${2:-}" ]]; then
                log_error "--rollback-to requires a revision number"
                exit 1
            fi
            ROLLBACK_ONLY=true
            ROLLBACK_REVISION="$2"
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            PRE_UPDATE_CHECKS=false
            POST_UPDATE_VALIDATION=false
            ;;
        --no-wait)
            UPDATE_TIMEOUT=0
            ;;
        --timeout)
            if [[ -z "${2:-}" ]]; then
                log_error "--timeout requires a value"
                exit 1
            fi
            UPDATE_TIMEOUT="$2"
            shift
            ;;
        --readiness-timeout)
            if [[ -z "${2:-}" ]]; then
                log_error "--readiness-timeout requires a value"
                exit 1
            fi
            READINESS_TIMEOUT="$2"
            shift
            ;;
        --max-unavailable)
            if [[ -z "${2:-}" ]]; then
                log_error "--max-unavailable requires a value"
                exit 1
            fi
            MAX_UNAVAILABLE="$2"
            shift
            ;;
        --max-surge)
            if [[ -z "${2:-}" ]]; then
                log_error "--max-surge requires a value"
                exit 1
            fi
            MAX_SURGE="$2"
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [[ -z "$RESOURCE_TYPE" ]]; then
                RESOURCE_TYPE="$1"
            elif [[ -z "$RESOURCE_NAME" ]]; then
                RESOURCE_NAME="$1"
            elif [[ -z "$IMAGE_NAME" && "$ROLLBACK_ONLY" != "true" ]]; then
                # Parse image name and tag
                if [[ "$1" =~ ^(.+):(.+)$ ]]; then
                    IMAGE_NAME="${BASH_REMATCH[1]}"
                    IMAGE_TAG="${BASH_REMATCH[2]}"
                else
                    IMAGE_NAME="$1"
                    IMAGE_TAG="latest"
                fi
            else
                log_error "Too many arguments provided"
                show_usage
                exit 1
            fi
            ;;
    esac
    shift
done

# Validate required arguments
if [[ -z "$RESOURCE_TYPE" ]]; then
    log_error "Resource type is required"
    show_usage
    exit 1
fi

if [[ -z "$RESOURCE_NAME" ]]; then
    log_error "Resource name is required"
    show_usage
    exit 1
fi

if [[ "$ROLLBACK_ONLY" != "true" && -z "$IMAGE_NAME" ]]; then
    log_error "Image name is required for update operations"
    show_usage
    exit 1
fi

# Handle signals gracefully
trap 'log_info "Rolling update interrupted"; exit 130' SIGINT SIGTERM

# Run main function
main "$@"
