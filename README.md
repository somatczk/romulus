# Romulus — ZimaOS Server Configuration

Homelab configuration for ZimaCube (Ryzen 9 5950X, 128GB RAM, GTX 1650 SUPER) running ZimaOS v1.5.4.

## Architecture

10 Docker Compose stacks:

| Stack | Services | RAM |
|-------|----------|-----|
| **core** | Traefik, Socket Proxy, Cloudflare DDNS, AdGuard | 960 MB |
| **security** | Authelia, CrowdSec, Bouncer | 640 MB |
| **media** | Jellyfin, Sonarr, Radarr, FlareSolverr, Prowlarr, Bazarr, Lidarr, qBittorrent, Jellyseerr | 11 GB |
| **productivity** | Nextcloud, Immich, Home Assistant, Paperless-ngx, Actual Budget, Homebox (+ PostgreSQL/Redis) | 26.5 GB |
| **monitoring** | Prometheus, Grafana, Loki, Promtail, Node/GPU/SMART/Restic Exporters, cAdvisor, Uptime Kuma, Glances | 5.1 GB |
| **ci** | GitHub Actions Runners (x10), Socket Proxy | 60.1 GB |
| **notifications** | ntfy | 256 MB |
| **utilities** | Watchtower, Dozzle, Speedtest, Portainer, TeamSpeak, Autoheal | 2.6 GB |
| **dashboard** | Homepage | 512 MB |
| **ai** | Ollama, OpenClaw, Open WebUI, Socket Proxy | ~19 GB |

Image versions pinned in single-line Dockerfiles (`stacks/<stack>/<service>/Dockerfile`). Dependabot opens weekly PRs for bumps, auto-merged after CI passes.

## Deployment

```bash
cp stacks/.env.example stacks/.env  # fill in secrets
./deploy.sh                          # full deploy
./deploy.sh media ai verify          # selective
./deploy.sh --port 2222 verify       # after SSH hardening
```

On the server: `cd /DATA/stacks/stacks && docker compose --env-file .env -f <stack>/compose.yml up -d --build`

## Service URLs

All at `*.romulus.hu` via Traefik + Authelia 2FA:

| Service | URL |
|---------|-----|
| Homepage | `romulus.hu` |
| Traefik | `traefik.romulus.hu` |
| AdGuard | `dns.romulus.hu` |
| Authelia | `auth.romulus.hu` |
| Jellyfin | `jellyfin.romulus.hu` |
| Sonarr / Radarr / Prowlarr / Bazarr / Lidarr | `sonarr.` / `radarr.` / `prowlarr.` / `bazarr.` / `lidarr.romulus.hu` |
| qBittorrent | `qbit.romulus.hu` |
| Jellyseerr | `requests.romulus.hu` |
| Nextcloud | `cloud.romulus.hu` |
| Immich | `photos.romulus.hu` |
| Home Assistant | `home.romulus.hu` |
| Paperless-ngx | `paperless.romulus.hu` |
| Actual Budget | `budget.romulus.hu` |
| Homebox | `homebox.romulus.hu` |
| Grafana | `grafana.romulus.hu` |
| Uptime Kuma | `status.romulus.hu` |
| ntfy | `notify.romulus.hu` |
| Dozzle | `logs.romulus.hu` |
| Speedtest | `speed.romulus.hu` |
| Portainer | `portainer.romulus.hu` |
| TeamSpeak | `teamspeak.romulus.hu` |
| OpenClaw | `ai.romulus.hu` |
| Open WebUI | `chat.romulus.hu` |

## GPU Sharing

GTX 1650 SUPER (4GB VRAM) shared between:
- **Jellyfin** — NVENC/NVDEC transcoding (~200-500MB/stream)
- **Immich ML** — Face/object recognition (~1-2GB)
- **Ollama** — Hybrid CPU+GPU inference (~1-2GB, tunable via `OLLAMA_NUM_GPU`)

CI runners are CPU-only to prevent VRAM contention.

## Security

LAN + ZeroTier only. SSH on port 2222 (key-only). Firewall defaults to DROP. Authelia 2FA on admin services. CrowdSec for threat intelligence. TLS 1.3 + HSTS everywhere. Docker socket proxied read-only. Backups AES-256 encrypted with restic.

## Backup

```bash
sudo /DATA/stacks/scripts/backup.sh           # run backup
restic -r /media/HDD-Storage/backups/restic-repo snapshots  # check
restic restore latest --target /tmp/restore    # restore
```

BTRFS snapshots managed by `scripts/btrfs-snapshot.sh`.
