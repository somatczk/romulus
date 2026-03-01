# ZimaOS Server Configuration

Complete homelab configuration for ZimaCube (Ryzen 9 5950X, 128GB RAM, GTX 1650 SUPER) running ZimaOS v1.5.4.

## Architecture

9 independent Docker Compose stacks, each with its own lifecycle:

| Stack | Services | RAM Budget |
|-------|----------|------------|
| **core** | Traefik, Docker Socket Proxy, AdGuard Home | 1 GB |
| **security** | Authelia, CrowdSec, Traefik Bouncer | 640 MB |
| **media** | Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, Lidarr, qBittorrent, Jellyseerr | 7.5 GB |
| **productivity** | Nextcloud + PostgreSQL + Redis, Immich + PostgreSQL + Redis + ML, Home Assistant, Paperless-ngx + PostgreSQL + Redis, Actual Budget, Homebox | 26 GB |
| **monitoring** | Prometheus, Grafana, Loki, Promtail, Node Exporter, cAdvisor, GPU Exporter, Restic Exporter, Uptime Kuma, Glances, SMART Exporter | 4.5 GB |
| **ci** | GitHub Actions Runners (x8), CI Socket Proxy | 48 GB |
| **notifications** | ntfy | 256 MB |
| **utilities** | Watchtower, Dozzle, Speedtest Tracker + Exporter, Portainer, TeamSpeak + MariaDB, Autoheal | 2.5 GB |
| **dashboard** | Homepage | 256 MB |

**Total: ~91 GB** of 128 GB — 37 GB headroom for burst workloads.

## Directory Structure

```
zimaos-config/
├── stacks/                  # Docker Compose stacks
│   ├── .env                 # Shared environment variables (git-ignored)
│   ├── .env.example          # Template with changeme_ placeholders
│   ├── core/compose.yml
│   ├── security/compose.yml
│   ├── media/compose.yml
│   ├── productivity/compose.yml
│   ├── monitoring/compose.yml
│   ├── ci/compose.yml
│   ├── notifications/compose.yml
│   ├── dashboard/compose.yml
│   └── utilities/compose.yml
├── configs/                 # Application configs
│   ├── authelia/            # Authentication config + user database
│   ├── traefik/             # Static + dynamic config
│   ├── prometheus/          # Scrape config + alert rules
│   ├── grafana/             # Provisioning (datasources, dashboards)
│   ├── loki/                # Log aggregation config
│   ├── promtail/            # Log shipping config
│   ├── crowdsec/            # Acquisition config
│   ├── homepage/            # Dashboard layout + widgets
│   └── samba/               # SMB shares config
├── scripts/                 # Operational scripts
│   ├── setup.sh             # Create directories + Docker networks
│   ├── cleanup.sh           # Phase 0: remove stale data
│   ├── firewall.sh          # iptables rules
│   ├── ssh-hardening.sh     # SSH security config
│   ├── backup.sh            # Restic backup with pg_dump
│   ├── btrfs-snapshot.sh    # BTRFS snapshot management
│   ├── btrfs-maintenance.sh # Scrub + balance
│   ├── restore-test.sh      # Monthly restore validation
│   └── install-crons.sh     # Install all cron jobs
├── docker/
│   └── daemon.json          # Docker daemon configuration
├── deploy.sh                # Master deployment script
└── README.md
```

## Prerequisites

- SSH access to ZimaOS server (default: `somatczk@192.168.0.3`)
- ZeroTier VPN connected (for remote access)
- NVIDIA container runtime installed (already on ZimaOS)
- rsync installed locally

## Configuration

### Required: Edit `.env` before deploying

Open `stacks/.env` and replace all `changeme_*` values:

| Variable | Description | How to get |
|----------|-------------|------------|
| `CF_API_TOKEN` | Cloudflare DNS API token | CF Dashboard → API Tokens → Zone:DNS:Edit |
| `GITHUB_PAT` | GitHub Personal Access Token | GitHub → Settings → Developer → Fine-grained PAT |
| `GITHUB_OWNER` | GitHub username or org | Your GitHub username |
| `GITHUB_REPO` | Repository for runners | Target repository name |
| `NEXTCLOUD_DB_PASSWORD` | Nextcloud PostgreSQL password | Generate strong password |
| `IMMICH_DB_PASSWORD` | Immich PostgreSQL password | Generate strong password |
| `RESTIC_PASSWORD` | Backup encryption key | Generate strong password, **store in password manager** |

### Optional: CrowdSec bouncer key

After CrowdSec is running, generate a bouncer key:
```bash
docker exec crowdsec cscli bouncers add traefik-bouncer
```
Update `CROWDSEC_BOUNCER_API_KEY` in `stacks/security/compose.yml`.

## Deployment

### Full deployment (recommended for first run)

```bash
# Edit secrets first!
vim stacks/.env

# Deploy everything
./deploy.sh
```

### Selective deployment

```bash
# Only sync files and start core infrastructure
./deploy.sh sync phase1 phase2

# Start media stack after core is up
./deploy.sh --skip-sync media

# After SSH hardening, use port 2222
./deploy.sh --port 2222 verify
```

### Individual stack management

Once deployed, manage stacks directly on the server:

```bash
# Start a stack
cd /DATA/stacks && docker compose -f stacks/media/compose.yml up -d

# Stop a stack
cd /DATA/stacks && docker compose -f stacks/media/compose.yml down

# View logs
cd /DATA/stacks && docker compose -f stacks/media/compose.yml logs -f jellyfin

# Restart a single service
cd /DATA/stacks && docker compose -f stacks/media/compose.yml restart sonarr

# Update images
cd /DATA/stacks && docker compose -f stacks/media/compose.yml pull && \
docker compose -f stacks/media/compose.yml up -d
```

## Service URLs

All services accessible via `*.romulus.hu` (requires DNS rewrite via AdGuard or Cloudflare):

| Service | URL | Notes |
|---------|-----|-------|
| Homepage | `https://romulus.hu` | Main dashboard |
| Traefik | `https://traefik.romulus.hu` | Reverse proxy dashboard |
| AdGuard | `https://dns.romulus.hu` | DNS + ad blocking |
| Jellyfin | `https://jellyfin.romulus.hu` | Media streaming |
| Sonarr | `https://sonarr.romulus.hu` | TV management |
| Radarr | `https://radarr.romulus.hu` | Movie management |
| Prowlarr | `https://prowlarr.romulus.hu` | Indexer management |
| Bazarr | `https://bazarr.romulus.hu` | Subtitles |
| Lidarr | `https://lidarr.romulus.hu` | Music management |
| qBittorrent | `https://qbit.romulus.hu` | Download client |
| Jellyseerr | `https://requests.romulus.hu` | Media requests |
| Nextcloud | `https://cloud.romulus.hu` | File sync + office |
| Immich | `https://photos.romulus.hu` | Photo management |
| Home Assistant | `https://home.romulus.hu` | Home automation |
| Grafana | `https://grafana.romulus.hu` | Dashboards + alerting |
| Uptime Kuma | `https://status.romulus.hu` | Status page |
| ntfy | `https://notify.romulus.hu` | Push notifications |
| Dozzle | `https://logs.romulus.hu` | Real-time logs |
| Speedtest | `https://speed.romulus.hu` | ISP speed tracking |
| Portainer | `https://portainer.romulus.hu` | Docker management |
| Paperless-ngx | `https://paperless.romulus.hu` | Document management |
| Actual Budget | `https://budget.romulus.hu` | Budget tracking |
| Homebox | `https://homebox.romulus.hu` | Home inventory |
| Glances | `https://glances.romulus.hu` | System monitoring |

## Backup & Recovery

### Manual backup
```bash
ssh -p 2222 somatczk@192.168.0.3
sudo /DATA/stacks/scripts/backup.sh
```

### Check backup status
```bash
export RESTIC_REPOSITORY=/media/HDD-Storage/backups/restic-repo
export RESTIC_PASSWORD=<your-password>
restic snapshots
restic check
```

### Restore from backup
```bash
# List snapshots
restic snapshots

# Restore specific snapshot to temp directory
restic restore <snapshot-id> --target /tmp/restore-test

# Restore specific path
restic restore latest --target /tmp/restore --include /media/SSD-Storage/appdata/media/jellyfin
```

### BTRFS snapshot rollback
```bash
# List snapshots
sudo btrfs subvolume list /media/SSD-Storage

# Rollback (example - adapt paths)
sudo btrfs subvolume snapshot /media/SSD-Storage/.snapshots/<timestamp> /media/SSD-Storage/appdata
```

## Security

- **Network access**: LAN (192.168.0.0/24) + ZeroTier (172.22.0.0/16) only
- **SSH**: Port 2222, key-only authentication, AllowUsers somatczk
- **Firewall**: Default DROP on INPUT, explicit allows for LAN/ZeroTier/Docker
- **CrowdSec**: Community threat intelligence + local log analysis
- **Docker socket**: Proxied through tecnativa/docker-socket-proxy (read-only for most services)
- **TLS**: 1.3 minimum, HSTS, security headers on all services
- **Backups**: AES-256 encrypted with restic, deduplicated

## GPU Sharing

GTX 1650 SUPER (4GB VRAM) shared between:
- **Jellyfin** — NVENC/NVDEC hardware transcoding (~200-500MB per stream)
- **Immich ML** — Face/object recognition (~1-2GB for model)
- **NOT** CI runners — CPU-only to prevent VRAM contention

## Monitoring & Alerting

- **Metrics**: Prometheus → Grafana (host, containers, GPU, Docker, Traefik)
- **Logs**: Promtail → Loki → Grafana (all container + system logs)
- **Uptime**: Uptime Kuma (HTTP/TCP/Ping checks for all services)
- **Alerts**: Grafana → ntfy push notifications
- **Quick debug**: Dozzle for real-time container log viewing

### Alert rules (configured in Grafana)
- Disk usage > 80% → warning, > 90% → critical
- Container OOM / restart loop → critical
- GPU temp > 80°C → warning
- Backup missed → critical
- Service down > 5 min → critical

## Verification Checklist

After deployment, verify:

- [ ] `docker ps` — all containers healthy
- [ ] `curl -I https://jellyfin.romulus.hu` — valid TLS, 200/302
- [ ] Traefik dashboard shows all routers
- [ ] AdGuard resolves `*.romulus.hu` → 192.168.0.3
- [ ] `ssh -p 2222 zimaos` works, password auth rejected
- [ ] `sudo iptables -L -n` shows DROP default policy
- [ ] CrowdSec: `docker exec crowdsec cscli decisions list`
- [ ] Jellyfin GPU transcoding works (check NVENC in playback info)
- [ ] *arr apps can reach Prowlarr + qBittorrent
- [ ] Nextcloud: `docker exec nextcloud php occ status`
- [ ] Immich ML processes a test photo
- [ ] GitHub runner visible in repo Settings → Actions → Runners
- [ ] Grafana dashboards load with live data
- [ ] Loki shows logs in Grafana Explore
- [ ] ntfy receives test notification on mobile
- [ ] `restic snapshots` shows backup entry
- [ ] `sudo btrfs subvolume list /media/SSD-Storage` shows snapshots
- [ ] Homepage shows all services
- [ ] Watchtower log shows monitor mode active
