#!/bin/bash

# Homeserver Infrastructure Deployment Script
# 
# Purpose: Automated deployment and management of homeserver infrastructure
# Features: Environment validation, service orchestration, health checks
# Usage: ./scripts/deploy.sh [options]
# 
# Deployment Phases:
# 1. Pre-flight checks (environment, dependencies, storage)
# 2. Core infrastructure (networks, databases, reverse proxy)
# 3. Service deployment (media, gaming, monitoring)
# 4. Security layer (authentication, intrusion prevention)
# 5. Post-deployment validation and health checks
#
# Requirements:
# - Docker and Docker Compose installed
# - Proper .env configuration
# - Required storage directories mounted
# - Network connectivity for external dependencies

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/tmp/homeserver-deploy-$(date +%Y%m%d-%H%M%S).log"
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml"
RUNNER_COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.runner.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log_info() {
    log "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    log "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    log "${RED}[ERROR]${NC} $1"
}

log_success() {
    log "${GREEN}[SUCCESS]${NC} $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command '$1' not found"
        return 1
    fi
}

check_file() {
    if [[ ! -f "$1" ]]; then
        log_error "Required file '$1' not found"
        return 1
    fi
}

check_directory() {
    if [[ ! -d "$1" ]]; then
        log_error "Required directory '$1' not found"
        return 1
    fi
}

wait_for_service() {
    local service_name="$1"
    local max_attempts=30
    local attempt=0
    
    log_info "Waiting for $service_name to become healthy..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker-compose $COMPOSE_FILES ps "$service_name" | grep -q "Up (healthy)"; then
            log_success "$service_name is healthy"
            return 0
        fi
        
        ((attempt++))
        log_info "Attempt $attempt/$max_attempts: $service_name not ready yet..."
        sleep 10
    done
    
    log_error "$service_name failed to become healthy within $(($max_attempts * 10)) seconds"
    return 1
}

preflight_checks() {
    log_info "Starting pre-flight checks..."
    
    # Check required commands
    check_command docker
    check_command docker-compose
    check_command curl
    check_command jq
    
    # Check Docker is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    
    # Check project structure
    cd "$PROJECT_DIR"
    check_file "docker-compose.yml"
    check_file "docker-compose.monitoring.yml"
    check_file "docker-compose.security.yml"
    check_file ".env"
    check_directory "configs"
    check_directory "scripts"
    
    # Load environment variables
    source .env
    
    # Validate critical environment variables
    required_vars=(
        "DOMAIN"
        "CLOUDFLARE_API_TOKEN"
        "MYSQL_ROOT_PASSWORD"
        "REDIS_PASSWORD"
        "PLEX_CLAIM"
        "GF_SECURITY_ADMIN_PASSWORD"
        "AUTHELIA_JWT_SECRET"
        "AUTHELIA_SESSION_SECRET"
        "AUTHELIA_STORAGE_ENCRYPTION_KEY"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required environment variable '$var' is not set"
            exit 1
        fi
    done
    
    # Check storage paths
    for path_var in "NVME_PATH" "SSD_PATH" "HDD_PATH"; do
        path_value="${!path_var}"
        if [[ ! -d "$path_value" ]]; then
            log_warn "Storage path '$path_value' does not exist, creating..."
            mkdir -p "$path_value" || {
                log_error "Failed to create storage path '$path_value'"
                exit 1
            }
        fi
    done
    
    # Create required subdirectories
    storage_dirs=(
        "${SSD_PATH}/caddy/data"
        "${SSD_PATH}/caddy/config"
        "${SSD_PATH}/databases/mariadb"
        "${SSD_PATH}/databases/redis"
        "${SSD_PATH}/config/plex"
        "${SSD_PATH}/config/qbittorrent"
        "${SSD_PATH}/config/teamspeak"
        "${SSD_PATH}/config/authelia"
        "${SSD_PATH}/monitoring/prometheus"
        "${SSD_PATH}/monitoring/grafana"
        "${SSD_PATH}/monitoring/loki"
        "${SSD_PATH}/monitoring/alertmanager"
        "${SSD_PATH}/monitoring/uptime-kuma"
        "${NVME_PATH}/games/cs2"
        "${HDD_PATH}/media"
        "${HDD_PATH}/downloads/complete"
    )
    
    for dir in "${storage_dirs[@]}"; do
        mkdir -p "$dir" || {
            log_error "Failed to create directory '$dir'"
            exit 1
        }
    done
    
    # Set proper permissions
    log_info "Setting storage permissions..."
    sudo chown -R "${PUID}:${PGID}" "${SSD_PATH}" "${NVME_PATH}" "${HDD_PATH}" 2>/dev/null || true
    
    log_success "Pre-flight checks completed"
}

deploy_core_infrastructure() {
    log_info "Deploying core infrastructure..."
    
    # Create Docker networks
    docker network create frontend --driver bridge --subnet 172.20.0.0/16 2>/dev/null || true
    docker network create backend --driver bridge --internal --subnet 172.21.0.0/16 2>/dev/null || true
    docker network create monitoring --driver bridge --internal --subnet 172.22.0.0/16 2>/dev/null || true
    
    # Deploy core services
    docker-compose $COMPOSE_FILES up -d caddy cloudflare-ddns mariadb redis
    
    # Wait for databases to be ready
    wait_for_service "mariadb"
    wait_for_service "redis"
    wait_for_service "caddy"
    
    log_success "Core infrastructure deployed"
}

deploy_media_services() {
    log_info "Deploying media services..."
    
    # Deploy media services
    docker-compose $COMPOSE_FILES up -d plex qbittorrent
    
    # Wait for services to be ready
    wait_for_service "plex"
    wait_for_service "qbittorrent"
    
    log_success "Media services deployed"
}

deploy_gaming_services() {
    log_info "Deploying gaming services..."
    
    # Deploy gaming services
    docker-compose $COMPOSE_FILES up -d teamspeak cs2-server
    
    # Wait for services to be ready
    wait_for_service "teamspeak"
    wait_for_service "cs2-server"
    
    log_success "Gaming services deployed"
}

deploy_monitoring_stack() {
    log_info "Deploying monitoring stack..."
    
    # Deploy monitoring services
    docker-compose $COMPOSE_FILES up -d \
        prometheus grafana loki promtail \
        node-exporter cadvisor alertmanager \
        mariadb-exporter redis-exporter blackbox-exporter \
        uptime-kuma
    
    # Wait for core monitoring services
    wait_for_service "prometheus"
    wait_for_service "grafana"
    wait_for_service "loki"
    wait_for_service "uptime-kuma"
    
    log_success "Monitoring stack deployed"
}

deploy_security_layer() {
    log_info "Deploying security layer..."
    
    # Deploy security services
    docker-compose $COMPOSE_FILES up -d authelia fail2ban
    
    # Wait for security services
    wait_for_service "authelia"
    
    log_success "Security layer deployed"
}

deploy_runner_service() {
    log_info "Deploying GitHub Actions runner..."
    
    # Check if runner configuration is provided
    if [[ -z "${GITHUB_REPOSITORY:-}" ]] || [[ -z "${GITHUB_RUNNER_TOKEN:-}" ]]; then
        log_warn "GitHub runner variables not configured, skipping runner deployment"
        log_info "To enable GitHub runner, set GITHUB_REPOSITORY and GITHUB_RUNNER_TOKEN in .env"
        return 0
    fi
    
    # Create runner directories
    create_directory "${SSD_PATH}/runner"
    create_directory "${SSD_PATH}/runner/work"
    create_directory "${SSD_PATH}/runner/cache"
    create_directory "${SSD_PATH}/runner/tools"
    
    # Deploy runner services
    log_info "Starting GitHub runner services..."
    docker-compose $RUNNER_COMPOSE_FILES up -d github-runner runner-cache
    
    # Wait for runner to register
    log_info "Waiting for runner registration..."
    wait_for_service "github-runner" 120
    
    # Verify runner is registered
    sleep 10
    if docker-compose $RUNNER_COMPOSE_FILES logs github-runner | grep -q "Runner successfully started"; then
        log_success "GitHub runner registered and started successfully"
    elif docker-compose $RUNNER_COMPOSE_FILES logs github-runner | grep -q "Listener started"; then
        log_success "GitHub runner listener started successfully"
    else
        log_warn "GitHub runner may not have registered properly, check logs:"
        log_warn "docker-compose $RUNNER_COMPOSE_FILES logs github-runner"
    fi
    
    log_success "GitHub runner deployment completed"
}

validate_deployment() {
    log_info "Validating deployment..."
    
    # Check all services are running
    local failed_services=()
    
    while IFS= read -r service; do
        if ! docker-compose $COMPOSE_FILES ps "$service" | grep -q "Up"; then
            failed_services+=("$service")
        fi
    done < <(docker-compose $COMPOSE_FILES config --services)
    
    # Also check runner services if configured
    if [[ -n "${GITHUB_REPOSITORY:-}" ]] && [[ -n "${GITHUB_RUNNER_TOKEN:-}" ]]; then
        while IFS= read -r service; do
            if ! docker-compose $RUNNER_COMPOSE_FILES ps "$service" | grep -q "Up"; then
                failed_services+=("$service")
            fi
        done < <(docker-compose -f docker-compose.runner.yml config --services)
    fi
    
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log_error "Failed services: ${failed_services[*]}"
        return 1
    fi
    
    # Test external connectivity
    log_info "Testing external connectivity..."
    
    # Wait a bit for services to fully initialize
    sleep 30
    
    # Test HTTP endpoints
    test_urls=(
        "https://monitoring.${DOMAIN}/api/health"
        "https://status.${DOMAIN}"
    )
    
    for url in "${test_urls[@]}"; do
        if curl -f -s --max-time 10 "$url" > /dev/null; then
            log_success "✓ $url"
        else
            log_warn "✗ $url (may need more time to initialize)"
        fi
    done
    
    log_success "Deployment validation completed"
}

main() {
    log_info "Starting homeserver infrastructure deployment..."
    log_info "Log file: $LOG_FILE"
    
    cd "$PROJECT_DIR"
    
    # Execute deployment phases
    preflight_checks
    deploy_core_infrastructure
    deploy_media_services
    deploy_gaming_services
    deploy_monitoring_stack
    deploy_security_layer
    deploy_runner_service
    validate_deployment
    
    log_success "Homeserver infrastructure deployment completed successfully!"
    log_info ""
    log_info "Access your services:"
    log_info "  • Plex: https://plex.${DOMAIN}"
    log_info "  • qBittorrent: https://torrents.${DOMAIN}"
    log_info "  • Grafana: https://monitoring.${DOMAIN}"
    log_info "  • Uptime Kuma: https://status.${DOMAIN}"
    log_info "  • TeamSpeak: ts.${DOMAIN}:9987"
    log_info "  • CS2 Server: Connect via ${DOMAIN}:27015"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Complete Plex setup at https://plex.${DOMAIN}"
    log_info "  2. Configure qBittorrent at https://torrents.${DOMAIN}"
    log_info "  3. Review monitoring dashboards at https://monitoring.${DOMAIN}"
    log_info "  4. Set up Uptime Kuma monitoring at https://status.${DOMAIN}"
    log_info "  5. Configure TeamSpeak admin token (check logs)"
    log_info ""
    log_info "For troubleshooting, check:"
    log_info "  • Deployment log: $LOG_FILE"
    log_info "  • Service logs: docker-compose $COMPOSE_FILES logs [service]"
    log_info "  • Service status: docker-compose $COMPOSE_FILES ps"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi