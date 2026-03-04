#!/usr/bin/env bash
# =============================================================================
# ZimaOS - Master Setup Script
# =============================================================================
# Creates the full directory structure, sets ownership, creates Docker networks,
# and prepares the system for stack deployment.
#
# Usage: sudo bash setup.sh
# =============================================================================
set -euo pipefail

# --- Configuration ---
PUID=999
PGID=1000
SSD="/media/SSD-Storage"
HDD="/media/HDD-Storage"
APPDATA="${SSD}/appdata"
TRAEFIK_ACME="${APPDATA}/core/traefik/acme.json"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (sudo)."
    exit 1
fi

if ! command -v docker &>/dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
fi

# =============================================================================
# 1. Create Directory Structure
# =============================================================================
log_info "Creating directory structure..."

# SSD appdata directories (matches plan Architecture → Storage Layout)
SSD_DIRS=(
    # Core
    "${APPDATA}/core/traefik/dynamic"
    "${APPDATA}/core/adguard"
    # Security
    "${APPDATA}/security/crowdsec/config"
    "${APPDATA}/security/crowdsec/db"
    "${APPDATA}/security/crowdsec/hub"
    "${APPDATA}/security/authelia"
    # Media
    "${APPDATA}/media/jellyfin/config"
    "${APPDATA}/media/jellyfin/cache"
    "${APPDATA}/media/sonarr"
    "${APPDATA}/media/radarr"
    "${APPDATA}/media/prowlarr"
    "${APPDATA}/media/bazarr"
    "${APPDATA}/media/lidarr"
    "${APPDATA}/media/qbittorrent"
    "${APPDATA}/media/jellyseerr"
    # Productivity
    "${APPDATA}/productivity/nextcloud/html"
    "${APPDATA}/productivity/nextcloud/data"
    "${APPDATA}/productivity/nextcloud-db"
    "${APPDATA}/productivity/nextcloud-redis"
    "${APPDATA}/productivity/immich/db"
    "${APPDATA}/productivity/immich/redis"
    "${APPDATA}/productivity/immich/ml-cache"
    "${APPDATA}/productivity/immich/upload"
    "${APPDATA}/productivity/homeassistant"
    "${APPDATA}/productivity/paperless/data"
    "${APPDATA}/productivity/paperless/media"
    "${APPDATA}/productivity/paperless/consume"
    "${APPDATA}/productivity/paperless-db"
    "${APPDATA}/productivity/actual-budget"
    "${APPDATA}/productivity/homebox"
    # Monitoring
    "${APPDATA}/monitoring/prometheus/data"
    "${APPDATA}/monitoring/grafana"
    "${APPDATA}/monitoring/loki"
    "${APPDATA}/monitoring/uptime-kuma"
    # CI
    "${APPDATA}/ci/runners/runner-1"
    "${APPDATA}/ci/runners/runner-2"
    "${APPDATA}/ci/runners/runner-3"
    "${APPDATA}/ci/runners/runner-4"
    "${APPDATA}/ci/runners/runner-solhouse-1"
    "${APPDATA}/ci/runners/runner-solhouse-2"
    "${APPDATA}/ci/runners/runner-solhouse-3"
    "${APPDATA}/ci/runners/runner-solhouse-4"
    "${APPDATA}/ci/runners/runner-romulus-1"
    "${APPDATA}/ci/runners/runner-romulus-2"
    "${APPDATA}/ci/runners/runner-romulus-3"
    "${APPDATA}/ci/runners/runner-romulus-4"
    # Notifications
    "${APPDATA}/notifications/ntfy/cache"
    "${APPDATA}/notifications/ntfy/etc"
    # Dashboard
    "${APPDATA}/dashboard/homepage"
    # Utilities
    "${APPDATA}/utilities/speedtest"
    "${APPDATA}/utilities/portainer"
    "${APPDATA}/utilities/teamspeak"
    "${APPDATA}/utilities/teamspeak-db"
    # Backups
    "${APPDATA}/backups/db-dumps"
    # AI
    "${APPDATA}/ai/ollama"
    "${APPDATA}/ai/openclaw"
    "${APPDATA}/ai/openclaw-workspace"
    "${APPDATA}/ai/open-webui"
)

# HDD directories
HDD_DIRS=(
    "${HDD}/media/movies"
    "${HDD}/media/series"
    "${HDD}/media/music"
    "${HDD}/media/photos"
    "${HDD}/downloads/complete"
    "${HDD}/downloads/incomplete"
    "${HDD}/downloads/torrents"
    "${HDD}/backups/restic-repo"
    "${HDD}/snapshots"
)

for dir in "${SSD_DIRS[@]}" "${HDD_DIRS[@]}"; do
    mkdir -p "$dir"
done

log_info "Directory structure created."

# =============================================================================
# 2. Set Ownership
# =============================================================================
log_info "Setting ownership to ${PUID}:${PGID}..."

chown -R "${PUID}:${PGID}" "${APPDATA}"
chown -R "${PUID}:${PGID}" "${HDD}/media"
chown -R "${PUID}:${PGID}" "${HDD}/downloads"
chown -R "${PUID}:${PGID}" "${HDD}/backups"
chown -R "${PUID}:${PGID}" "${HDD}/snapshots"

log_info "Ownership set."

# =============================================================================
# 3. Create Traefik ACME file
# =============================================================================
log_info "Creating Traefik ACME certificate store..."

touch "${TRAEFIK_ACME}"
chmod 600 "${TRAEFIK_ACME}"
chown "${PUID}:${PGID}" "${TRAEFIK_ACME}"

log_info "acme.json created with mode 600."

# =============================================================================
# 4. Fix Docker config.json permissions
# =============================================================================
# CasaOS/ZimaOS creates /DATA/.docker/config.json as root, causing
# "WARNING: Error loading config file" when non-root users run Docker CLI.
log_info "Fixing Docker config.json permissions..."

DOCKER_CONFIG_DIR="/DATA/.docker"
mkdir -p "${DOCKER_CONFIG_DIR}"
if [ ! -f "${DOCKER_CONFIG_DIR}/config.json" ]; then
    echo '{}' > "${DOCKER_CONFIG_DIR}/config.json"
fi
chmod 755 "${DOCKER_CONFIG_DIR}"
chmod 644 "${DOCKER_CONFIG_DIR}/config.json"

log_info "Docker config.json permissions fixed."

# =============================================================================
# 5. Create Docker Networks
# =============================================================================
log_info "Creating Docker networks..."

declare -A NETWORKS
# network_name -> "internal|external"
NETWORKS=(
    ["proxy"]="external"
    ["socket"]="internal"
    ["media"]="internal"
    ["db-nextcloud"]="internal"
    ["db-immich"]="internal"
    ["monitoring"]="internal"
    ["ci"]="internal"
    ["db-paperless"]="internal"
    ["ai"]="internal"
)

for net in "${!NETWORKS[@]}"; do
    if docker network inspect "$net" &>/dev/null; then
        log_warn "Network '${net}' already exists, skipping."
    else
        if [[ "${NETWORKS[$net]}" == "internal" ]]; then
            docker network create --driver bridge --internal "$net"
            log_info "Created internal network: ${net}"
        else
            docker network create --driver bridge "$net"
            log_info "Created network: ${net}"
        fi
    fi
done

# =============================================================================
# 6. Create Metrics Directory (for node-exporter textfile collector)
# =============================================================================
log_info "Creating metrics directory for textfile collector..."
mkdir -p /var/lib/node_exporter/textfile_collector
log_info "Metrics directory created."

# =============================================================================
# 7. Install Restic
# =============================================================================
log_info "Ensuring restic is installed..."

mkdir -p /DATA/bin
if ! command -v restic &>/dev/null && [ ! -f /DATA/bin/restic ]; then
    log_info "Installing restic..."
    RESTIC_VERSION="0.17.3"
    curl -sSL "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" \
        | bunzip2 > /DATA/bin/restic
    chmod +x /DATA/bin/restic
    log_info "Restic ${RESTIC_VERSION} installed to /DATA/bin/restic"
else
    log_info "Restic already available, skipping."
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}=============================================================================${NC}"
echo -e "${GREEN} ZimaOS setup complete!${NC}"
echo -e "${GREEN}=============================================================================${NC}"
echo ""
echo "  Directories created under:"
echo "    - ${APPDATA}/"
echo "    - ${HDD}/"
echo ""
echo "  Docker networks created:"
for net in "${!NETWORKS[@]}"; do
    echo "    - ${net} (${NETWORKS[$net]})"
done
echo ""
echo "  Next steps:"
echo "    1. Edit stacks/.env and replace all changeme_ values"
echo "    2. Copy docker/daemon.json to /etc/docker/daemon.json"
echo "    3. Run: sudo systemctl restart docker"
echo "    4. Run: sudo bash scripts/swap.sh (configure 8GB swap + kernel tuning)"
echo "    5. Deploy stacks in order: core -> security -> media -> productivity -> monitoring -> ci -> notifications -> dashboard -> utilities -> ai"
echo ""
