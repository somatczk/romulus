#!/bin/bash

# Homeserver Infrastructure Health Check Script
# 
# Purpose: Comprehensive health validation for all homeserver services
# Features: Service status, connectivity, resource usage, external access
# Usage: ./scripts/healthcheck.sh [--verbose] [--json]
# 
# Health Checks:
# 1. Docker service status and health
# 2. Network connectivity between services
# 3. External HTTPS access validation
# 4. Resource usage monitoring
# 5. Storage availability checks
# 6. Database connectivity
# 7. Security service validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml"
RUNNER_COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.runner.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Options
VERBOSE=false
JSON_OUTPUT=false

# Health check results
HEALTH_RESULTS=()

log_info() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    fi
}

log_warning() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${YELLOW}[WARNING]${NC} $1"
    fi
}

log_error() {
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${RED}[ERROR]${NC} $1"
    fi
}

add_result() {
    local category="$1"
    local name="$2"
    local status="$3"
    local details="${4:-}"
    
    HEALTH_RESULTS+=("{\"category\":\"$category\",\"name\":\"$name\",\"status\":\"$status\",\"details\":\"$details\"}")
}

check_docker_services() {
    log_info "Checking Docker services..."
    
    cd "$PROJECT_DIR"
    local all_services
    all_services=$(docker-compose $COMPOSE_FILES config --services)
    
    local healthy_count=0
    local total_count=0
    
    while IFS= read -r service; do
        ((total_count++))
        
        # Check if service is running
        if docker-compose $COMPOSE_FILES ps "$service" 2>/dev/null | grep -q "Up"; then
            # Check health status
            local health_status
            health_status=$(docker inspect "$(docker-compose $COMPOSE_FILES ps -q "$service" 2>/dev/null)" 2>/dev/null | jq -r '.[0].State.Health.Status // "none"' 2>/dev/null || echo "none")
            
            if [[ "$health_status" == "healthy" || "$health_status" == "none" ]]; then
                log_success "$service"
                add_result "docker" "$service" "healthy" "Service is running and healthy"
                ((healthy_count++))
            else
                log_warning "$service (unhealthy: $health_status)"
                add_result "docker" "$service" "unhealthy" "Health status: $health_status"
            fi
        else
            log_error "$service (not running)"
            add_result "docker" "$service" "down" "Service is not running"
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            # Show resource usage
            local stats
            stats=$(docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep "$service" || echo "N/A")
            if [[ "$stats" != "N/A" ]]; then
                log_info "  Resources: $stats"
            fi
        fi
    done <<< "$all_services"
    
    log_info "Docker services: $healthy_count/$total_count healthy"
}

check_network_connectivity() {
    log_info "Checking network connectivity..."
    
    # Test internal service connectivity
    local services_to_test=(
        "caddy:80:Caddy HTTP"
        "prometheus:9090:Prometheus"
        "grafana:3000:Grafana"
        "mariadb:3306:MariaDB"
        "redis:6379:Redis"
    )
    
    for service_test in "${services_to_test[@]}"; do
        IFS=':' read -r service port description <<< "$service_test"
        
        if docker exec caddy nc -z "$service" "$port" 2>/dev/null; then
            log_success "$description connectivity"
            add_result "network" "$service" "connected" "Port $port is accessible"
        else
            log_error "$description connectivity"
            add_result "network" "$service" "disconnected" "Port $port is not accessible"
        fi
    done
}

check_external_access() {
    log_info "Checking external HTTPS access..."
    
    # Load domain from environment
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        source "$PROJECT_DIR/.env"
    else
        log_error "Could not load .env file"
        return 1
    fi
    
    local external_urls=(
        "https://plex.${DOMAIN}:Plex Media Server"
        "https://torrents.${DOMAIN}:qBittorrent WebUI"
        "https://monitoring.${DOMAIN}:Grafana Dashboard"
        "https://status.${DOMAIN}:Uptime Kuma"
    )
    
    for url_test in "${external_urls[@]}"; do
        IFS=':' read -r url description <<< "$url_test"
        
        local response_code
        response_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --insecure "$url" || echo "000")
        
        if [[ "$response_code" =~ ^[23] ]]; then
            log_success "$description ($response_code)"
            add_result "external" "$description" "accessible" "HTTP $response_code"
        elif [[ "$response_code" == "401" || "$response_code" == "403" ]]; then
            log_success "$description (protected - $response_code)"
            add_result "external" "$description" "protected" "HTTP $response_code - authentication required"
        else
            log_error "$description ($response_code)"
            add_result "external" "$description" "inaccessible" "HTTP $response_code"
        fi
    done
    
    # Check SSL certificates
    log_info "Checking SSL certificates..."
    
    for url_test in "${external_urls[@]}"; do
        IFS=':' read -r url description <<< "$url_test"
        
        local cert_expiry
        cert_expiry=$(echo | openssl s_client -servername "${url#https://}" -connect "${url#https://}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep "notAfter" | cut -d= -f2 || echo "")
        
        if [[ -n "$cert_expiry" ]]; then
            local expiry_epoch
            expiry_epoch=$(date -d "$cert_expiry" +%s 2>/dev/null || echo "0")
            local current_epoch
            current_epoch=$(date +%s)
            local days_until_expiry
            days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))
            
            if [[ "$days_until_expiry" -gt 30 ]]; then
                log_success "SSL cert for $description (expires in $days_until_expiry days)"
                add_result "ssl" "$description" "valid" "Expires in $days_until_expiry days"
            elif [[ "$days_until_expiry" -gt 0 ]]; then
                log_warning "SSL cert for $description expires in $days_until_expiry days"
                add_result "ssl" "$description" "expiring_soon" "Expires in $days_until_expiry days"
            else
                log_error "SSL cert for $description has expired"
                add_result "ssl" "$description" "expired" "Certificate has expired"
            fi
        else
            log_warning "Could not check SSL cert for $description"
            add_result "ssl" "$description" "unknown" "Could not retrieve certificate information"
        fi
    done
}

check_resource_usage() {
    log_info "Checking system resource usage..."
    
    # CPU usage
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "0")
    if (( $(echo "$cpu_usage < 80" | bc -l 2>/dev/null || echo "1") )); then
        log_success "CPU usage: ${cpu_usage}%"
        add_result "resources" "cpu" "normal" "${cpu_usage}%"
    else
        log_warning "High CPU usage: ${cpu_usage}%"
        add_result "resources" "cpu" "high" "${cpu_usage}%"
    fi
    
    # Memory usage
    local mem_info
    mem_info=$(free | grep Mem)
    local total_mem used_mem
    total_mem=$(echo "$mem_info" | awk '{print $2}')
    used_mem=$(echo "$mem_info" | awk '{print $3}')
    local mem_percent
    mem_percent=$(echo "scale=1; $used_mem * 100 / $total_mem" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$mem_percent < 85" | bc -l 2>/dev/null || echo "1") )); then
        log_success "Memory usage: ${mem_percent}%"
        add_result "resources" "memory" "normal" "${mem_percent}%"
    else
        log_warning "High memory usage: ${mem_percent}%"
        add_result "resources" "memory" "high" "${mem_percent}%"
    fi
    
    # Disk usage for storage paths
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        source "$PROJECT_DIR/.env"
        
        for path_var in "NVME_PATH" "SSD_PATH" "HDD_PATH"; do
            local path_value="${!path_var:-}"
            if [[ -n "$path_value" && -d "$path_value" ]]; then
                local disk_usage
                disk_usage=$(df "$path_value" | tail -1 | awk '{print $5}' | cut -d'%' -f1)
                
                if [[ "$disk_usage" -lt 80 ]]; then
                    log_success "${path_var}: ${disk_usage}%"
                    add_result "storage" "$path_var" "normal" "${disk_usage}%"
                elif [[ "$disk_usage" -lt 90 ]]; then
                    log_warning "${path_var}: ${disk_usage}%"
                    add_result "storage" "$path_var" "warning" "${disk_usage}%"
                else
                    log_error "${path_var}: ${disk_usage}% (critical)"
                    add_result "storage" "$path_var" "critical" "${disk_usage}%"
                fi
            fi
        done
    fi
}

check_databases() {
    log_info "Checking database connectivity..."
    
    # MariaDB
    if docker exec mariadb mysqladmin ping -h localhost 2>/dev/null | grep -q "mysqld is alive"; then
        log_success "MariaDB connectivity"
        add_result "database" "mariadb" "connected" "Database is responding"
    else
        log_error "MariaDB connectivity"
        add_result "database" "mariadb" "disconnected" "Database is not responding"
    fi
    
    # Redis
    if docker exec redis redis-cli ping 2>/dev/null | grep -q "PONG"; then
        log_success "Redis connectivity"
        add_result "database" "redis" "connected" "Cache is responding"
    else
        log_error "Redis connectivity"
        add_result "database" "redis" "disconnected" "Cache is not responding"
    fi
}

check_security_services() {
    log_info "Checking security services..."
    
    # Authelia
    local authelia_health
    authelia_health=$(curl -s --max-time 5 http://localhost:9091/api/health 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
    
    if [[ "$authelia_health" == "UP" ]]; then
        log_success "Authelia authentication service"
        add_result "security" "authelia" "healthy" "Authentication service is running"
    else
        log_error "Authelia authentication service"
        add_result "security" "authelia" "unhealthy" "Authentication service is not responding"
    fi
    
    # Fail2ban
    if docker exec fail2ban fail2ban-client status 2>/dev/null | grep -q "Status"; then
        log_success "Fail2ban intrusion prevention"
        add_result "security" "fail2ban" "active" "Intrusion prevention is active"
    else
        log_warning "Fail2ban status unknown"
        add_result "security" "fail2ban" "unknown" "Could not determine status"
    fi
}

check_runner_services() {
    log_info "Checking GitHub Actions runner..."
    
    # Check if runner is configured
    if [[ -z "${GITHUB_REPOSITORY:-}" ]] || [[ -z "${GITHUB_RUNNER_TOKEN:-}" ]]; then
        log_info "INFO: GitHub runner not configured, skipping checks"
        add_result "runner" "configuration" "disabled" "Runner not configured"
        return 0
    fi
    
    # Check if runner service is running
    if docker-compose $RUNNER_COMPOSE_FILES ps github-runner 2>/dev/null | grep -q "Up"; then
        log_success "GitHub runner service is running"
        add_result "runner" "service" "running" "Runner container is active"
        
        # Check runner registration status
        local runner_logs
        runner_logs=$(docker-compose $RUNNER_COMPOSE_FILES logs --tail=50 github-runner 2>/dev/null)
        
        if echo "$runner_logs" | grep -q "Listening for Jobs"; then
            log_success "GitHub runner is listening for jobs"
            add_result "runner" "status" "listening" "Runner is ready to accept jobs"
        elif echo "$runner_logs" | grep -q "Runner successfully started"; then
            log_success "GitHub runner started successfully"
            add_result "runner" "status" "started" "Runner has started"
        else
            log_warning "GitHub runner status unclear"
            add_result "runner" "status" "unknown" "Could not determine runner status"
        fi
        
        # Check runner cache service
        if docker-compose $RUNNER_COMPOSE_FILES ps runner-cache 2>/dev/null | grep -q "Up"; then
            log_success "Runner cache service is running"
            add_result "runner" "cache" "running" "Cache service is active"
        else
            log_warning "Runner cache service not running"
            add_result "runner" "cache" "stopped" "Cache service is not active"
        fi
        
    else
        log_error "GitHub runner service not running"
        add_result "runner" "service" "stopped" "Runner container is not running"
    fi
    
    # Check runner storage
    if [[ -d "${SSD_PATH}/runner" ]]; then
        local runner_disk_usage
        runner_disk_usage=$(du -sh "${SSD_PATH}/runner" 2>/dev/null | cut -f1 || echo "unknown")
        log_info "INFO: Runner storage usage: $runner_disk_usage"
        add_result "runner" "storage" "available" "Storage: $runner_disk_usage"
    else
        log_warning "Runner storage directory not found"
        add_result "runner" "storage" "missing" "Runner directory not created"
    fi
}

generate_summary() {
    local total_checks=0
    local healthy_checks=0
    local warning_checks=0
    local error_checks=0
    
    for result in "${HEALTH_RESULTS[@]}"; do
        ((total_checks++))
        local status
        status=$(echo "$result" | jq -r '.status')
        
        case "$status" in
            "healthy"|"normal"|"connected"|"accessible"|"protected"|"valid"|"active")
                ((healthy_checks++))
                ;;
            "warning"|"expiring_soon"|"high"|"unknown")
                ((warning_checks++))
                ;;
            *)
                ((error_checks++))
                ;;
        esac
    done
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "{"
        echo "  \"summary\": {"
        echo "    \"total_checks\": $total_checks,"
        echo "    \"healthy\": $healthy_checks,"
        echo "    \"warnings\": $warning_checks,"
        echo "    \"errors\": $error_checks,"
        echo "    \"overall_status\": \"$(if [[ $error_checks -eq 0 ]]; then echo "healthy"; elif [[ $warning_checks -gt 0 ]]; then echo "warning"; else echo "error"; fi)\""
        echo "  },"
        echo "  \"checks\": ["
        printf "    %s" "${HEALTH_RESULTS[0]}"
        for result in "${HEALTH_RESULTS[@]:1}"; do
            printf ",\n    %s" "$result"
        done
        echo
        echo "  ]"
        echo "}"
    else
        echo
        log_info "=== HEALTH CHECK SUMMARY ==="
        log_info "Total checks: $total_checks"
        log_success "Healthy: $healthy_checks"
        if [[ $warning_checks -gt 0 ]]; then
            log_warning "Warnings: $warning_checks"
        fi
        if [[ $error_checks -gt 0 ]]; then
            log_error "Errors: $error_checks"
        fi
        
        echo
        if [[ $error_checks -eq 0 && $warning_checks -eq 0 ]]; then
            log_success "All systems are healthy!"
        elif [[ $error_checks -eq 0 ]]; then
            log_warning "System is operational with warnings"
        else
            log_error "System has critical issues requiring attention"
        fi
    fi
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                VERBOSE=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --help)
                echo "Usage: $0 [--verbose] [--json]"
                echo "  --verbose    Show detailed information"
                echo "  --json       Output results in JSON format"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    if [[ "$JSON_OUTPUT" == "false" ]]; then
        echo -e "${CYAN}=== HOMESERVER HEALTH CHECK ===${NC}"
        echo "$(date)"
        echo
    fi
    
    cd "$PROJECT_DIR"
    
    # Run health checks
    check_docker_services
    check_network_connectivity
    check_external_access
    check_resource_usage
    check_databases
    check_security_services
    check_runner_services
    
    # Generate summary
    generate_summary
    
    # Exit with appropriate code
    local error_count=0
    for result in "${HEALTH_RESULTS[@]}"; do
        local status
        status=$(echo "$result" | jq -r '.status')
        if [[ ! "$status" =~ ^(healthy|normal|connected|accessible|protected|valid|active|warning|expiring_soon|high|unknown)$ ]]; then
            ((error_count++))
        fi
    done
    
    exit $((error_count > 0 ? 1 : 0))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi