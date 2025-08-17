# Secret Management Guide

## Overview

This homeserver infrastructure uses a multi-layered approach to secret management to keep sensitive data secure while enabling automated deployment through GitHub Actions.

## File Structure

- `.env.example` - Template with placeholder values (committed to git)
- `.env` - Local environment file with real secrets (gitignored)
- GitHub Secrets - Encrypted secrets for CI/CD workflows

## Setup Instructions

### 1. Local Development

```bash
# Copy template and fill in real values
cp .env.example .env
# Edit .env with your actual secrets
nano .env
```

### 2. GitHub Actions Secrets

Configure these secrets in your repository settings:

#### Required Secrets
- `SSH_PRIVATE_KEY` - SSH key for homeserver access
- `SSH_USER` - Username for SSH connection
- `SERVER_HOST` - IP/hostname of homeserver
- `GITHUB_TOKEN` - Automatically provided by GitHub

#### Optional Secrets (if using external services)
- `DISCORD_WEBHOOK_URL` - For deployment notifications
- `BACKUP_ENCRYPTION_KEY` - For encrypted backups

### 3. Production Deployment

The deployment process:
1. GitHub Actions connects to homeserver via SSH
2. Repository is cloned/updated on homeserver
3. Local `.env` file on homeserver provides runtime secrets
4. Docker Compose uses environment variables from `.env`

## Security Best Practices

### Environment Variables
- Never commit `.env` files with real secrets
- Use strong, unique passwords (32+ characters)
- Rotate secrets regularly
- Use different secrets for different environments

### GitHub Secrets
- Store only deployment-related secrets in GitHub
- Use least privilege principle
- Regularly audit secret access

### Homeserver
- Protect `.env` file with appropriate permissions (600)
- Use dedicated service accounts where possible
- Enable fail2ban and monitoring for intrusion detection

## Secret Categories

### Database Secrets
```bash
MYSQL_ROOT_PASSWORD=          # MariaDB root password
REDIS_PASSWORD=               # Redis authentication
MONITORING_DB_PASSWORD=       # Monitoring database user
```

### Service Authentication
```bash
AUTHELIA_JWT_SECRET=          # JWT signing key (64 chars)
AUTHELIA_SESSION_SECRET=      # Session encryption (64 chars)
GF_SECURITY_ADMIN_PASSWORD=   # Grafana admin password
```

### External API Keys
```bash
CLOUDFLARE_API_TOKEN=         # DNS management
PLEX_CLAIM=                   # Plex server setup
STEAM_TOKEN=                  # CS2 server registration
```

### Backup Encryption
```bash
BACKUP_ENCRYPTION_KEY=        # File encryption (32 chars)
B2_ACCOUNT_KEY=              # Cloud storage access
```

## Troubleshooting

### Common Issues
1. **Service fails to start** - Check if environment variables are set
2. **Authentication errors** - Verify secret values match configuration
3. **GitHub Actions failure** - Ensure required secrets are configured

### Verification Commands
```bash
# Check if .env is loaded
docker-compose config

# Test database connection
docker exec mariadb mysqladmin ping -u root -p

# Verify Redis authentication
docker exec redis redis-cli -a "$REDIS_PASSWORD" ping
```

## Migration

When rotating secrets:
1. Update `.env` file on homeserver
2. Update GitHub repository secrets
3. Restart affected services
4. Verify connectivity and functionality