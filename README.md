# Romulus Homeserver Infrastructure

A simplified, production-ready homeserver setup using Docker Compose with automated deployment via GitHub Actions.

## 🖥️ Server Specifications

- **CPU**: AMD Ryzen 9 5950X (16-core/32-thread)
- **Memory**: 64GB DDR4
- **Storage**: 
  - NVMe SSD: High-performance storage for containers and game files
  - SATA SSD: Database storage and active data
  - HDD: Media libraries and bulk storage
- **GPU**: NVIDIA GTX 1060 (for Plex hardware transcoding)

## 🚀 Services & Ports

### Core Services
- **Caddy**: Reverse proxy with automatic HTTPS (ports 80/443)
- **MariaDB**: Database server for TeamSpeak and other services
- **Redis**: Session management and caching

### Media Services
- **Plex**: Media server with GPU transcoding (port 32400)
- **qBittorrent**: Torrent client with web interface (port 8080)

### Gaming Services  
- **TeamSpeak 3**: Voice communication server (port 9987)
- **Counter-Strike 2**: Dedicated game server (port 27015)

### Monitoring Services
- **Prometheus**: Metrics collection (port 9090)
- **Grafana**: Metrics visualization and dashboards (port 3000)
- **Loki**: Log aggregation
- **Various exporters**: System and service metrics

### Security Services
- **Fail2Ban**: Intrusion prevention system

## 📁 Project Structure

```
romulus/
├── .github/workflows/
│   └── deploy.yml              # Automated deployment workflow
├── configs/                    # Service configuration files
│   ├── caddy/                 # Reverse proxy configuration
│   ├── prometheus/            # Monitoring configuration
│   ├── grafana/              # Dashboard configuration
│   └── ...                   # Other service configs
├── docker-compose.yml         # Core services
├── docker-compose.monitoring.yml  # Monitoring stack
├── docker-compose.security.yml    # Security services
├── docker-compose.runner.yml      # GitHub Actions runner
├── .env.template              # Environment template for local dev
└── README.md                  # This file
```

## ⚙️ Setup Instructions

### 1. Server Prerequisites

```bash
# Install Docker and Docker Compose
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Create storage directories
sudo mkdir -p /mnt/{nvme,ssd,hdd}
sudo chown $USER:$USER /mnt/{nvme,ssd,hdd}
```

### 2. GitHub Actions Runner Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/romulus.git /opt/homeserver
cd /opt/homeserver

# Copy environment template (for local development only)
cp .env.template .env

# Start the GitHub runner
docker-compose -f docker-compose.runner.yml up -d
```

### 3. GitHub Repository Configuration

Configure the following GitHub Secrets in your repository settings:

#### Required Secrets (All Must Be Set)
- `DOMAIN`: Your domain name (e.g., `example.com`)
- `CLOUDFLARE_API_TOKEN`: Cloudflare API token for DNS management
- `MYSQL_ROOT_PASSWORD`: MariaDB root password
- `REDIS_PASSWORD`: Redis authentication password
- `PLEX_CLAIM`: Plex claim token from https://plex.tv/claim
- `GF_SECURITY_ADMIN_PASSWORD`: Grafana admin password

#### Service-Specific Secrets
- `QBITTORRENT_PASSWORD`: qBittorrent WebUI password
- `CS2_SERVER_NAME`: Counter-Strike 2 server name
- `CS2_RCON_PASSWORD`: CS2 RCON password
- `CS2_SERVER_PASSWORD`: CS2 server password (optional)
- `STEAM_TOKEN`: Steam game server token
- `TS3_SERVER_ADMIN_PASSWORD`: TeamSpeak admin password

#### System Configuration Secrets
- `TZ`: Timezone (e.g., `UTC`, `America/New_York`)
- `PUID`/`PGID`: User/Group IDs (e.g., `1000`)
- `NVME_PATH`/`SSD_PATH`/`HDD_PATH`: Storage mount paths
- `CLOUDFLARE_DOMAINS`: Comma-separated list of domains to manage DNS for

#### Resource Limit Secrets
- `PLEX_MEMORY_LIMIT`/`PLEX_CPU_LIMIT`: Plex resource limits
- `CS2_MEMORY_LIMIT`/`CS2_CPU_LIMIT`: CS2 server resource limits
- `RUNNER_MEMORY_LIMIT`/`RUNNER_CPU_LIMIT`: GitHub runner resource limits

#### Port Configuration Secrets
- `PLEX_PORT`, `QBITTORRENT_PORT`, `GRAFANA_PORT`, `PROMETHEUS_PORT`
- `TEAMSPEAK_VOICE_PORT`, `TEAMSPEAK_QUERY_PORT`, `TEAMSPEAK_FILES_PORT`
- `CS2_PORT`, `CS2_RCON_PORT`

#### Monitoring & Alerting Secrets
- `DISCORD_WEBHOOK_URL`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`
- `MONITORING_DB_PASSWORD`

#### GitHub Runner Secrets
- `GITHUB_REPOSITORY`, `GITHUB_RUNNER_TOKEN`, `RUNNER_NAME`, `RUNNER_GROUP`, `PROJECT_PATH`

### 4. Runner Permissions

The GitHub runner needs proper permissions to manage Docker containers:

```bash
# Add runner user to docker group
sudo usermod -aG docker $(whoami)

# Ensure proper ownership of project directory
sudo chown -R $(whoami):$(whoami) /opt/homeserver

# Create required directories
sudo mkdir -p /mnt/{nvme,ssd,hdd}
sudo chown -R 1000:1000 /mnt/{nvme,ssd,hdd}
```

## 🔄 Deployment Process

### Automatic Deployment
- Push changes to the `main` branch
- GitHub Actions automatically deploys to your server
- The runner performs a fresh git pull and deploys all services
- Health checks ensure successful deployment

### Manual Deployment (Local)
```bash
# Deploy all services
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml up -d

# Deploy specific services
docker-compose -f docker-compose.yml up -d plex qbittorrent

# Check service status
docker-compose ps

# View logs
docker-compose logs [service-name]
```

## 🌐 Service Access

After deployment, services are available at:

- **Plex**: https://plex.yourdomain.com
- **qBittorrent**: https://torrents.yourdomain.com  
- **Grafana**: https://monitoring.yourdomain.com
- **TeamSpeak**: ts.yourdomain.com:9987
- **CS2 Server**: yourdomain.com:27015

## 🔧 Maintenance

### Updating Services
```bash
# Pull latest images
docker-compose pull

# Restart services
docker-compose up -d
```

### Viewing Logs
```bash
# All services
docker-compose logs

# Specific service
docker-compose logs plex

# Follow logs in real-time
docker-compose logs -f grafana
```

### Backup Important Data
```bash
# Backup configuration and data directories
tar -czf homeserver-backup.tar.gz /mnt/ssd/config /mnt/ssd/databases
```

## ❗ Troubleshooting

### Common Issues

1. **Services won't start**: Check logs with `docker-compose logs [service]`
2. **Permission errors**: Ensure proper ownership of storage directories
3. **Network issues**: Verify Cloudflare DNS settings and API tokens
4. **Runner offline**: Check GitHub runner logs with `docker logs github-runner`

### Storage Issues
```bash
# Check disk space
df -h /mnt/*

# Check directory permissions
ls -la /mnt/ssd/config/
```

### Network Issues
```bash
# Test DNS resolution
nslookup yourdomain.com

# Check open ports
netstat -tlnp | grep -E ':(80|443|32400)'
```

## 🛡️ Security Considerations

- All sensitive data is managed via GitHub Secrets
- Fail2Ban provides intrusion prevention
- Services run with minimal privileges
- Networks are properly segmented (frontend/backend/monitoring)
- Regular security updates via container image updates

## 📊 Monitoring & Alerting

- **Prometheus**: Collects metrics from all services
- **Grafana**: Provides dashboards and alerting
- **Loki**: Aggregates logs for analysis
- Health checks ensure service availability

Access monitoring at: https://monitoring.yourdomain.com

## 🔐 GitHub Runner Security

The self-hosted runner:
- Runs in an isolated Docker container  
- Has read-only access to the project code
- Uses GitHub Secrets for sensitive data
- Automatically pulls fresh code on each deployment
- Is properly resource-limited to prevent system interference

---

For questions or issues, please create a GitHub issue in this repository.