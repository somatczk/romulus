# Homeserver Infrastructure Setup Guide

Comprehensive setup guide for deploying a production-ready homeserver infrastructure using Docker.

## Prerequisites

### Hardware Requirements

- **CPU**: AMD 5950x (16 cores/32 threads) or equivalent high-performance processor
- **Memory**: 128GB RAM (minimum 64GB for full functionality)
- **GPU**: NVIDIA GTX 1060 or better (for Plex hardware transcoding)
- **Storage**:
  - 500GB NVMe SSD: Docker root, containers, game files
  - 500GB SATA SSD: Databases, cache, active data
  - 1TB+ HDD: Media libraries, completed downloads

### Software Requirements

- **Operating System**: Ubuntu 20.04 LTS or newer (recommended)
- **Docker**: Version 20.10 or newer
- **Docker Compose**: Version 2.0 or newer
- **Git**: For repository management
- **OpenSSL**: For certificate and encryption operations

### Network Requirements

- **Domain**: Registered domain with Cloudflare DNS management
- **Router**: DMZ configuration or proper port forwarding
- **Internet**: Stable high-speed connection (100+ Mbps recommended)
- **IPv4**: Static or dynamic IP with DDNS support

## Initial System Setup

### 1. System Preparation

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install -y curl wget git openssl bc jq fail2ban ufw

# Configure firewall (adjust ports as needed)
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 9987/udp  # TeamSpeak
sudo ufw allow 27015    # CS2 Server
sudo ufw --force enable
```

### 2. Docker Installation

```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker

# Install Docker Compose
sudo apt install -y docker-compose-plugin

# Verify installation
docker --version
docker compose version
```

### 3. Storage Configuration

```bash
# Create mount points (adjust paths as needed)
sudo mkdir -p /mnt/{nvme,ssd,hdd}

# Mount storage devices (add to /etc/fstab for persistence)
# Example fstab entries:
# /dev/nvme0n1p1 /mnt/nvme ext4 defaults,noatime 0 2
# /dev/sdb1 /mnt/ssd ext4 defaults,noatime 0 2
# /dev/sdc1 /mnt/hdd ext4 defaults,noatime 0 2

# Set ownership (replace 1000:1000 with your UID:GID)
sudo chown -R 1000:1000 /mnt/{nvme,ssd,hdd}
```

### 4. GPU Setup (for Plex Hardware Transcoding)

```bash
# Install NVIDIA drivers
sudo apt install -y nvidia-driver-470

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list

sudo apt update && sudo apt install -y nvidia-docker2
sudo systemctl restart docker

# Verify GPU access
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi
```

## Project Setup

### 1. Clone Repository

```bash
# Clone the homeserver infrastructure repository
git clone https://github.com/yourusername/homeserver.git
cd homeserver

# Make scripts executable
chmod +x scripts/*.sh
```

### 2. Environment Configuration

```bash
# Copy environment template
cp .env.example .env

# Edit environment variables
nano .env
```

### Critical Environment Variables

Edit `.env` file with your specific values:

```bash
# Basic Configuration
TZ=America/New_York
PUID=1000  # Your user ID
PGID=1000  # Your group ID
DOMAIN=yourdomain.com

# Storage Paths
NVME_PATH=/mnt/nvme
SSD_PATH=/mnt/ssd
HDD_PATH=/mnt/hdd

# Cloudflare (required for SSL)
CLOUDFLARE_API_TOKEN=your_api_token_here
CLOUDFLARE_ZONE_ID=your_zone_id_here
CLOUDFLARE_EMAIL=your@email.com

# Database Passwords (generate secure passwords)
MYSQL_ROOT_PASSWORD=your_secure_mysql_password
TS3SERVER_DB_PASSWORD=your_secure_ts3_password
REDIS_PASSWORD=your_secure_redis_password

# Service Configuration
PLEX_CLAIM=your_plex_claim_token
QBITTORRENT_PASSWORD=your_qbittorrent_password
GF_SECURITY_ADMIN_PASSWORD=your_grafana_password

# Security (generate 32-64 character random strings)
AUTHELIA_JWT_SECRET=your_64_char_jwt_secret
AUTHELIA_SESSION_SECRET=your_64_char_session_secret
AUTHELIA_STORAGE_ENCRYPTION_KEY=your_32_char_encryption_key
BACKUP_ENCRYPTION_KEY=your_32_char_backup_key

# Gaming Services
CS2_SERVER_NAME="Your CS2 Server"
CS2_RCON_PASSWORD=your_cs2_rcon_password
STEAM_TOKEN=your_steam_token

# Backup Configuration (optional)
B2_ACCOUNT_ID=your_b2_account_id
B2_ACCOUNT_KEY=your_b2_account_key
B2_BUCKET_NAME=homeserver-backups

# Notifications (optional)
DISCORD_WEBHOOK_URL=your_discord_webhook_url
```

### 3. Generate Secure Keys and Passwords

```bash
# Generate secure passwords and keys
echo "MySQL Root Password: $(openssl rand -base64 32)"
echo "Redis Password: $(openssl rand -base64 32)"
echo "JWT Secret (64 chars): $(openssl rand -base64 48)"
echo "Session Secret (64 chars): $(openssl rand -base64 48)"
echo "Encryption Key (32 chars): $(openssl rand -base64 24)"
echo "Backup Key (32 chars): $(openssl rand -base64 24)"
```

### 4. Cloudflare Configuration

1. **Create API Token**:
   - Go to Cloudflare Dashboard → My Profile → API Tokens
   - Create Token → Custom Token
   - Permissions:
     - Zone:Zone:Read
     - Zone:DNS:Edit
   - Zone Resources: Include specific zone

2. **Get Zone ID**:
   - Cloudflare Dashboard → Select your domain
   - Copy Zone ID from the right sidebar

3. **Configure DNS**:
   - Add A record: `@` pointing to your external IP
   - Add CNAME records for subdomains:
     - `plex` → `yourdomain.com`
     - `torrents` → `yourdomain.com`
     - `monitoring` → `yourdomain.com`
     - `status` → `yourdomain.com`
     - `auth` → `yourdomain.com`

## Deployment

### 1. Pre-Deployment Validation

```bash
# Run pre-flight checks
./scripts/deploy.sh --dry-run

# Validate Docker Compose configuration
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml config
```

### 2. Initial Deployment

```bash
# Deploy infrastructure (this will take 10-15 minutes)
./scripts/deploy.sh

# Monitor deployment progress
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml logs -f
```

### 3. Deployment Verification

```bash
# Run comprehensive health checks
./scripts/healthcheck.sh --verbose

# Check service status
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml ps

# Test external access
curl -I https://monitoring.yourdomain.com
curl -I https://plex.yourdomain.com
curl -I https://status.yourdomain.com
```

## Post-Deployment Configuration

### 1. Plex Media Server Setup

1. **Initial Setup**:
   - Visit `https://plex.yourdomain.com`
   - Sign in with your Plex account
   - Complete the initial server setup

2. **Hardware Transcoding**:
   - Settings → Transcoder
   - Enable "Use hardware acceleration when available"
   - Verify GPU is detected in Plex settings

3. **Media Libraries**:
   - Add libraries pointing to `/media` directories
   - Configure metadata agents and scanners

### 2. qBittorrent Configuration

1. **Initial Login**:
   - Visit `https://torrents.yourdomain.com`
   - Default username: `admin`
   - Password: from `QBITTORRENT_PASSWORD`

2. **Download Configuration**:
   - Downloads: `/downloads/incomplete` (SSD for active downloads)
   - Completed: `/downloads/complete` (HDD for storage)
   - Enable "Automatically add these trackers to new downloads"

### 3. TeamSpeak Server Setup

1. **Get Admin Token**:
   ```bash
   # Check TeamSpeak logs for admin token
   docker-compose logs teamspeak | grep -i "token"
   ```

2. **Connect to Server**:
   - Server address: `ts.yourdomain.com:9987`
   - Use admin token to gain server admin privileges

### 4. Counter-Strike 2 Server

1. **Server Configuration**:
   - Server appears as: `yourdomain.com:27015`
   - RCON access via: `rcon_password YOUR_RCON_PASSWORD`

2. **Game Configuration**:
   - Edit server configs in `/mnt/nvme/games/cs2/`
   - Customize maps, game modes, and server settings

### 5. Monitoring Setup

1. **Grafana Dashboard**:
   - Visit `https://monitoring.yourdomain.com`
   - Login: `admin` / `GF_SECURITY_ADMIN_PASSWORD`
   - Import pre-configured dashboards

2. **Uptime Kuma**:
   - Visit `https://status.yourdomain.com`
   - Create admin account
   - Add monitoring for all services

### 6. Authentication (Authelia)

1. **User Management**:
   ```bash
   # Generate password hash for new users
   docker run --rm authelia/authelia:latest authelia hash-password 'new_password'
   ```

2. **Add Users**:
   - Edit `configs/authelia/users_database.yml`
   - Add new users with generated password hashes
   - Restart Authelia: `docker-compose restart authelia`

## Maintenance

### Daily Tasks (Automated)

- **Backups**: Run at 2:00 AM daily via cron
- **Health Checks**: Continuous monitoring via Prometheus
- **Log Rotation**: Automatic via Docker and Loki retention

### Weekly Tasks

```bash
# Update container images
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml pull

# Restart services with new images
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml up -d

# Clean up unused images
docker system prune -f

# Check disk usage
df -h /mnt/*

# Review logs for issues
./scripts/healthcheck.sh --verbose
```

### Monthly Tasks

- **Security Updates**: Update host OS packages
- **Certificate Review**: Verify SSL certificate auto-renewal
- **Backup Verification**: Test backup restoration procedures
- **Performance Review**: Check resource usage trends
- **User Access Review**: Audit user accounts and permissions

## Troubleshooting

### Common Issues

1. **Services Won't Start**:
   ```bash
   # Check Docker daemon
   sudo systemctl status docker
   
   # Check logs
   docker-compose logs [service_name]
   
   # Check resource usage
   docker stats
   ```

2. **SSL Certificate Issues**:
   ```bash
   # Check Caddy logs
   docker-compose logs caddy
   
   # Verify Cloudflare API access
   curl -X GET "https://api.cloudflare.com/client/v4/zones" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
   ```

3. **External Access Problems**:
   ```bash
   # Check firewall
   sudo ufw status
   
   # Test DNS resolution
   nslookup monitoring.yourdomain.com
   
   # Check reverse proxy
   curl -I http://localhost/
   ```

### Getting Help

- **Logs**: Check service logs with `docker-compose logs [service]`
- **Health Checks**: Run `./scripts/healthcheck.sh --verbose`
- **Documentation**: See additional docs in `/docs` directory
- **Community**: Join relevant Discord servers or forums for specific services

## Security Considerations

### Network Security

- **Firewall**: Only expose necessary ports (80, 443, game servers)
- **VPN Access**: Consider VPN for administrative access
- **Regular Updates**: Keep all components updated
- **Monitoring**: Review security logs regularly

### Data Protection

- **Backups**: Automated encrypted backups to cloud storage
- **Encryption**: All sensitive data encrypted at rest
- **Access Control**: 2FA enabled for all administrative interfaces
- **Secrets Management**: Environment variables for all secrets

### Best Practices

- **Principle of Least Privilege**: Minimal permissions for all services
- **Network Segmentation**: Isolated Docker networks
- **Container Security**: Non-root users, dropped capabilities
- **Regular Audits**: Review configurations and access logs

This completes the comprehensive setup guide for your homeserver infrastructure. Follow each section carefully and refer to the troubleshooting section if you encounter any issues.