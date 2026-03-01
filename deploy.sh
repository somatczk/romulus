#!/bin/bash
set -euo pipefail

###############################################################################
# ZimaOS Configuration Deployment Script
# Deploys all stacks, configs, and scripts to the ZimaOS server
###############################################################################

# Configuration
REMOTE_USER="${REMOTE_USER:-somatczk}"
REMOTE_HOST="${REMOTE_HOST:-192.168.0.3}"
REMOTE_PORT="${REMOTE_PORT:-22}"  # Use 22 for first run, 2222 after SSH hardening
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

ssh_cmd() { ssh -p "${REMOTE_PORT}" "${REMOTE}" "$@"; }
scp_cmd() { scp -P "${REMOTE_PORT}" "$@"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [PHASE]

Options:
  -h, --help          Show this help
  -u, --user USER     Remote user (default: somatczk)
  -H, --host HOST     Remote host (default: 192.168.0.3)
  -p, --port PORT     SSH port (default: 22)
  --dry-run           Show what would be done without executing
  --skip-sync         Skip rsync, assume files already on server

Phases (run all if none specified):
  sync        Rsync files to server
  phase0      Cleanup old data
  phase1      Docker daemon, directories, networks
  phase2      Core stack (Traefik, socket proxy, AdGuard)
  phase3      Security stack (CrowdSec)
  phase4      SSH hardening + firewall
  media       Media stack
  productivity  Productivity stack
  ci          CI runners stack
  monitoring  Monitoring stack
  notifications  Notifications stack
  utilities   Utilities stack
  dashboard   Dashboard stack
  crons       Install cron jobs
  samba       Configure Samba
  verify      Run verification checks

Examples:
  $0                          # Full deployment
  $0 sync phase1 phase2       # Only sync + foundation + core
  $0 --port 2222 verify       # Verify on hardened SSH port
EOF
    exit 0
}

# Parse arguments
DRY_RUN=false
SKIP_SYNC=false
PHASES=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        -u|--user) REMOTE_USER="$2"; REMOTE="${REMOTE_USER}@${REMOTE_HOST}"; shift 2 ;;
        -H|--host) REMOTE_HOST="$2"; REMOTE="${REMOTE_USER}@${REMOTE_HOST}"; shift 2 ;;
        -p|--port) REMOTE_PORT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-sync) SKIP_SYNC=true; shift ;;
        *) PHASES+=("$1"); shift ;;
    esac
done

# If no phases specified, run all in order
if [[ ${#PHASES[@]} -eq 0 ]]; then
    PHASES=(sync phase0 phase1 phase2 phase3 media productivity ci monitoring notifications utilities dashboard crons samba phase4 verify)
fi

run() {
    if $DRY_RUN; then
        log "[DRY RUN] $*"
    else
        "$@"
    fi
}

###############################################################################
# Phase: Sync files to server
###############################################################################
do_sync() {
    log "Syncing configuration files to server..."
    if $SKIP_SYNC; then
        warn "Skipping sync (--skip-sync)"
        return 0
    fi

    rsync -avz --progress \
        -e "ssh -p ${REMOTE_PORT}" \
        --exclude='.git' \
        --exclude='.DS_Store' \
        --exclude='deploy.sh' \
        "${SCRIPT_DIR}/" \
        "${REMOTE}:/DATA/stacks/"

    ok "Files synced to ${REMOTE}:/DATA/stacks/"
}

###############################################################################
# Phase 0: Cleanup
###############################################################################
do_phase0() {
    log "Phase 0: Cleanup old data..."
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail
echo "Removing stale directories..."
rm -rf /media/SSD-Storage/openwebui/ 2>/dev/null || true
rm -rf /media/SSD-Storage/modelThins/ 2>/dev/null || true

echo "Fixing Docker config.json permissions..."
sudo mkdir -p /DATA/.docker
[ -f /DATA/.docker/config.json ] || sudo sh -c 'echo "{}" > /DATA/.docker/config.json'
sudo chmod 755 /DATA/.docker
sudo chmod 644 /DATA/.docker/config.json

echo "Stopping old CasaOS qBittorrent if running..."
if [ -f /DATA/.casaos/apps/qbittorrent/docker-compose.yml ]; then
    docker compose -f /DATA/.casaos/apps/qbittorrent/docker-compose.yml down 2>/dev/null || true
fi

echo "Adding user to docker group..."
sudo usermod -aG docker somatczk 2>/dev/null || true

echo "Phase 0 complete."
REMOTE_SCRIPT
    ok "Phase 0 cleanup done"
}

###############################################################################
# Phase 1: Docker daemon, directories, networks
###############################################################################
do_phase1() {
    log "Phase 1: Docker foundation..."
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail

# Install daemon.json
echo "Configuring Docker daemon..."
sudo cp /DATA/stacks/docker/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
echo "Docker daemon restarted with new config."

# Run setup script (creates dirs + networks)
echo "Running setup script..."
chmod +x /DATA/stacks/scripts/setup.sh
sudo /DATA/stacks/scripts/setup.sh

echo "Phase 1 complete."
REMOTE_SCRIPT
    ok "Phase 1 foundation done"
}

###############################################################################
# Phase 2: Core stack
###############################################################################
do_phase2() {
    log "Phase 2: Core stack (Traefik, Socket Proxy, AdGuard)..."
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail
cd /DATA/stacks/stacks
docker compose --env-file .env -f core/compose.yml up -d --build
echo "Waiting for Traefik to obtain certificates..."
sleep 15
docker compose --env-file .env -f core/compose.yml ps
REMOTE_SCRIPT
    ok "Core stack running"
}

###############################################################################
# Phase 3: Security stack
###############################################################################
do_phase3() {
    log "Phase 3: Security stack (CrowdSec)..."
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail
cd /DATA/stacks/stacks
docker compose --env-file .env -f security/compose.yml up -d --build
sleep 5
docker compose --env-file .env -f security/compose.yml ps
REMOTE_SCRIPT
    ok "Security stack running"
}

###############################################################################
# Phase 4: SSH hardening + firewall (run LAST to avoid lockout)
###############################################################################
do_phase4() {
    log "Phase 4: SSH hardening + firewall..."
    warn "This will change SSH to port 2222 and enable firewall."
    warn "Make sure you have ZeroTier or LAN access as fallback!"

    if ! $DRY_RUN; then
        read -r -p "Continue? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Skipped phase 4."; return 0; }
    fi

    # Install firewall first (doesn't break SSH)
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail
echo "Installing firewall rules..."
chmod +x /DATA/stacks/scripts/firewall.sh
sudo /DATA/stacks/scripts/firewall.sh
echo "Firewall rules applied."
REMOTE_SCRIPT
    ok "Firewall active"

    # Persist firewall rules
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail
echo "Persisting firewall rules..."
sudo apt-get install -y iptables-persistent 2>/dev/null || true
sudo netfilter-persistent save 2>/dev/null || true
REMOTE_SCRIPT
    ok "Firewall rules persisted"

    # SSH hardening restarts sshd on a new port, which will kill this connection.
    # Use nohup + background to let it finish after disconnect.
    warn "Applying SSH hardening (connection will drop when sshd restarts)..."
    ssh_cmd bash <<'REMOTE_SCRIPT' || true
chmod +x /DATA/stacks/scripts/ssh-hardening.sh
sudo nohup /DATA/stacks/scripts/ssh-hardening.sh > /tmp/ssh-hardening.log 2>&1 &
sleep 2
echo "SSH hardening launched in background."
REMOTE_SCRIPT
    # Give sshd time to restart
    sleep 5

    # Verify we can connect on the new port
    if ssh -p 2222 -o ConnectTimeout=5 "${REMOTE}" "echo 'SSH on port 2222: OK'" 2>/dev/null; then
        ok "SSH hardened (port 2222), firewall active"
    else
        warn "Could not verify SSH on port 2222. Check manually: ssh -p 2222 ${REMOTE}"
    fi
    warn "Update REMOTE_PORT to 2222 for future deployments!"
}

###############################################################################
# Application stacks (independent, can be parallelized)
###############################################################################
do_media() {
    log "Starting media stack..."
    ssh_cmd "cd /DATA/stacks/stacks && docker compose --env-file .env -f media/compose.yml up -d --build"
    ok "Media stack running"
}

do_productivity() {
    log "Starting productivity stack..."
    ssh_cmd "cd /DATA/stacks/stacks && docker compose --env-file .env -f productivity/compose.yml up -d --build"
    ok "Productivity stack running"
}

do_ci() {
    log "Starting CI stack..."
    ssh_cmd "cd /DATA/stacks/stacks && docker compose --env-file .env -f ci/compose.yml up -d --build"
    ok "CI stack running"
}

do_monitoring() {
    log "Starting monitoring stack..."
    ssh_cmd "cd /DATA/stacks/stacks && docker compose --env-file .env -f monitoring/compose.yml up -d --build"
    ok "Monitoring stack running"
}

do_notifications() {
    log "Starting notifications stack..."
    ssh_cmd "cd /DATA/stacks/stacks && docker compose --env-file .env -f notifications/compose.yml up -d --build"
    ok "Notifications stack running"
}

do_utilities() {
    log "Starting utilities stack..."
    ssh_cmd "cd /DATA/stacks/stacks && docker compose --env-file .env -f utilities/compose.yml up -d --build"
    ok "Utilities stack running"
}

do_dashboard() {
    log "Starting dashboard stack..."
    ssh_cmd "cd /DATA/stacks/stacks && docker compose --env-file .env -f dashboard/compose.yml up -d --build"
    ok "Dashboard stack running"
}

###############################################################################
# Cron jobs
###############################################################################
do_crons() {
    log "Installing cron jobs..."
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail
chmod +x /DATA/stacks/scripts/*.sh
sudo /DATA/stacks/scripts/install-crons.sh
echo "Cron jobs installed."
REMOTE_SCRIPT
    ok "Cron jobs installed"
}

###############################################################################
# Samba
###############################################################################
do_samba() {
    log "Configuring Samba..."
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail
if [ -f /etc/samba/smb.conf ]; then
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
fi
sudo cp /DATA/stacks/configs/samba/smb.conf /etc/samba/smb.conf
sudo systemctl restart smbd 2>/dev/null || sudo systemctl restart smb 2>/dev/null || true
echo "Samba configured."
REMOTE_SCRIPT
    ok "Samba configured"
}

###############################################################################
# Verification
###############################################################################
do_verify() {
    log "Running verification checks..."
    ssh_cmd bash <<'REMOTE_SCRIPT'
set -euo pipefail

echo ""
echo "=== Container Status ==="
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | head -50

echo ""
echo "=== Docker Networks ==="
docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}' | grep -E 'proxy|socket|media|db-|monitoring|ci'

echo ""
echo "=== Disk Usage ==="
df -h /DATA /media/SSD-Storage /media/HDD-Storage 2>/dev/null || true

echo ""
echo "=== BTRFS Status ==="
sudo btrfs filesystem show /media/SSD-Storage 2>/dev/null || true
sudo btrfs filesystem show /media/HDD-Storage 2>/dev/null || true

echo ""
echo "=== Firewall Rules ==="
sudo iptables -L INPUT -n --line-numbers 2>/dev/null | head -20

echo ""
echo "=== SSH Config ==="
grep -E '^(Port|PasswordAuthentication|PermitRootLogin|AllowUsers)' /etc/ssh/sshd_config 2>/dev/null || true

echo ""
echo "=== Quick Health Checks ==="
# Check Traefik
curl -sk -o /dev/null -w "Traefik: %{http_code}\n" https://traefik.romulus.hu 2>/dev/null || echo "Traefik: unreachable"
# Check Jellyfin
curl -sk -o /dev/null -w "Jellyfin: %{http_code}\n" https://jellyfin.romulus.hu 2>/dev/null || echo "Jellyfin: unreachable"
# Check Grafana
curl -sk -o /dev/null -w "Grafana: %{http_code}\n" https://grafana.romulus.hu 2>/dev/null || echo "Grafana: unreachable"
# Check Homepage
curl -sk -o /dev/null -w "Homepage: %{http_code}\n" https://romulus.hu 2>/dev/null || echo "Homepage: unreachable"

echo ""
echo "=== GPU Status ==="
nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv,noheader 2>/dev/null || echo "nvidia-smi not available"

echo ""
echo "=== Verification Complete ==="
REMOTE_SCRIPT
    ok "Verification done"
}

###############################################################################
# Main execution
###############################################################################
log "ZimaOS Deployment starting..."
log "Target: ${REMOTE} (port ${REMOTE_PORT})"
log "Phases: ${PHASES[*]}"
echo ""

for phase in "${PHASES[@]}"; do
    case $phase in
        sync)           run do_sync ;;
        phase0)         run do_phase0 ;;
        phase1)         run do_phase1 ;;
        phase2)         run do_phase2 ;;
        phase3)         run do_phase3 ;;
        phase4)         run do_phase4 ;;
        media)          run do_media ;;
        productivity)   run do_productivity ;;
        ci)             run do_ci ;;
        monitoring)     run do_monitoring ;;
        notifications)  run do_notifications ;;
        utilities)      run do_utilities ;;
        dashboard)      run do_dashboard ;;
        crons)          run do_crons ;;
        samba)          run do_samba ;;
        verify)         run do_verify ;;
        *) err "Unknown phase: $phase"; exit 1 ;;
    esac
    echo ""
done

log "Deployment complete!"
echo ""
echo "Next steps:"
echo "  1. Update .env with real secrets (CF_API_TOKEN, GITHUB_PAT, etc.)"
echo "  2. Configure AdGuard Home at https://dns.romulus.hu (first-run wizard)"
echo "  3. Set up Nextcloud at https://cloud.romulus.hu"
echo "  4. Configure Immich at https://photos.romulus.hu"
echo "  5. Set up Grafana dashboards at https://grafana.romulus.hu"
echo "  6. Configure Uptime Kuma monitors at https://status.romulus.hu"
echo "  7. Install ntfy app on mobile and subscribe to topics"
echo "  8. Initialize restic repo: restic -r /media/HDD-Storage/backups/restic-repo init"
echo "  9. Test backup: /DATA/stacks/scripts/backup.sh"
