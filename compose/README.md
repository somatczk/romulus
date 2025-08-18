# Docker Compose Service Organization

This directory contains Docker Compose files organized by service category for better maintainability and selective deployment.

## Directory Structure

```
compose/
├── core/               # Essential infrastructure services
│   ├── proxy.yml       # Caddy reverse proxy + CloudFlare DDNS
│   ├── database.yml    # MariaDB database
│   └── cache.yml       # Redis cache
├── media/              # Media streaming and downloading
│   ├── plex.yml        # Plex media server
│   └── torrent.yml     # qBittorrent client
├── gaming/             # Gaming services
│   ├── teamspeak.yml   # TeamSpeak 3 voice server
│   └── cs2.yml         # Counter-Strike 2 dedicated server
├── monitoring/         # Observability stack
│   ├── metrics.yml     # Prometheus + Grafana
│   ├── logging.yml     # Loki + Promtail
│   ├── exporters.yml   # Node, cAdvisor, DB exporters
│   ├── alerting.yml    # Alertmanager
│   └── uptime.yml      # Uptime Kuma
├── security/           # Security services
│   └── fail2ban.yml    # Intrusion prevention
└── infrastructure/     # Development/deployment tools
    └── github-runner.yml # GitHub Actions self-hosted runner
```

## Usage Examples

### Deploy Everything
```bash
docker-compose up -d
```

### Deploy Specific Categories
```bash
# Core infrastructure only
docker-compose -f compose/core/proxy.yml -f compose/core/database.yml -f compose/core/cache.yml up -d

# Media services only
docker-compose -f compose/media/plex.yml -f compose/media/torrent.yml up -d

# Monitoring stack only
docker-compose -f compose/monitoring/metrics.yml -f compose/monitoring/logging.yml up -d
```

### Deploy Individual Services
```bash
# Just Plex
docker-compose -f compose/media/plex.yml up -d

# Just monitoring metrics
docker-compose -f compose/monitoring/metrics.yml up -d
```

### Check Service Status
```bash
# All services
docker-compose ps

# Specific category
docker-compose -f compose/core/database.yml ps
```

### View Logs
```bash
# All services
docker-compose logs

# Specific service
docker-compose -f compose/media/plex.yml logs plex
```

## Benefits

1. **Selective Deployment**: Deploy only what you need
2. **Better Organization**: Services grouped by function
3. **Easier Maintenance**: Smaller files are easier to manage
4. **Faster Development**: Work on one service category at a time
5. **Resource Management**: Control resource usage per category
6. **Dependency Management**: Clear service dependencies

## Networks

All services use these shared networks defined in the root `docker-compose.yml`:

- **frontend**: Public-facing services (172.20.0.0/16)
- **backend**: Internal services only (172.21.0.0/16)  
- **monitoring**: Monitoring stack (172.22.0.0/16)

## Environment Variables

All services use the same environment variables defined in `.env.template`. Copy this to `.env` and fill in your values for local development.

Production deployments use GitHub Secrets automatically via the GitHub Actions workflow.