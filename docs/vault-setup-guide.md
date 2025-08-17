# HashiCorp Vault Secret Management Setup

## Overview

This setup provides centralized secret management using HashiCorp Vault (open source). Secrets are stored once in Vault and automatically synchronized to both the homeserver and GitHub Actions.

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│                 │    │                 │    │                 │
│ GitHub Actions  │────│ HashiCorp Vault │────│   Homeserver    │
│                 │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        │                        │                        │
        │                        │                        │
        ▼                        ▼                        ▼
 AppRole Auth           Secret Storage            Vault Agent
 (30min token)         (Encrypted KV)           (Auto-sync)
```

## Benefits

- **Single source of truth** - All secrets stored in one place
- **Automatic synchronization** - No manual secret copying
- **Secure authentication** - AppRole-based access control  
- **Audit logging** - Complete secret access history
- **Secret rotation** - Easy to update secrets everywhere
- **Encryption** - All secrets encrypted at rest and in transit

## Quick Setup

1. **Initialize Vault:**
   ```bash
   ./scripts/setup-vault.sh
   ```

2. **Add GitHub Secrets:**
   - `VAULT_ADDR`: `http://your-server-ip:8200`
   - `VAULT_ROLE_ID`: (from setup output)
   - `VAULT_SECRET_ID`: (from setup output)

3. **Update real secrets in Vault:**
   ```bash
   vault kv put kv/homeserver/database mysql_root_password=REAL_PASSWORD
   vault kv put kv/homeserver/cloudflare api_token=REAL_TOKEN
   # ... update all secrets
   ```

4. **Deploy with automatic secret sync:**
   ```bash
   git add . && git commit -m "Add Vault integration"
   git push origin main
   ```

## Secret Organization

Secrets are organized in logical groups:

### `/kv/homeserver/config`
- `TZ`, `PUID`, `PGID`, `DOMAIN`
- `NVME_PATH`, `SSD_PATH`, `HDD_PATH`
- `PROJECT_PATH`, `RUNNER_NAME`

### `/kv/homeserver/database`
- `mysql_root_password`
- `redis_password`
- `monitoring_password`
- `backup_password`

### `/kv/homeserver/services`
- `grafana_password`
- `qbittorrent_password`
- `plex_claim`

### `/kv/homeserver/authelia`
- `jwt_secret`
- `session_secret`
- `storage_key`

### `/kv/homeserver/cloudflare`
- `api_token`
- `zone_id`
- `email`

### `/kv/homeserver/gaming`
- `cs2_server_name`, `cs2_rcon_password`
- `steam_token`
- `ts3_admin_password`

### `/kv/homeserver/notifications`
- `discord_webhook`

### `/kv/homeserver/backup`
- `encryption_key`
- `b2_account_id`, `b2_account_key`
- `b2_bucket_name`

### `/kv/homeserver/github`
- `repository`
- `runner_token`

## How It Works

### On Deployment:
1. GitHub Actions authenticates with Vault using AppRole
2. Fetches all secrets from Vault KV store
3. Generates `.env` file on homeserver
4. Services restart with new secrets

### On Homeserver:
1. Vault Agent authenticates using local AppRole credentials
2. Monitors Vault for secret changes
3. Automatically generates new `.env` file when secrets change
4. Restarts affected services

### Secret Updates:
1. Update secret in Vault: `vault kv put kv/homeserver/database mysql_root_password=newpass`
2. Vault Agent detects change and updates `.env`
3. Services automatically restart with new secrets

## Management Commands

### View Secrets
```bash
vault kv get kv/homeserver/database
vault kv get -field=mysql_root_password kv/homeserver/database
```

### Update Secrets
```bash
vault kv put kv/homeserver/database mysql_root_password=newpassword
vault kv patch kv/homeserver/services grafana_password=newpassword
```

### List All Secret Paths
```bash
vault kv list kv/homeserver/
```

### Rotate GitHub Runner Token
```bash
# Manual GitHub Actions workflow dispatch
# Or via API:
vault kv patch kv/homeserver/github runner_token=new_token
```

## Security Features

### Authentication
- **AppRole method** - Machine-to-machine authentication
- **Short-lived tokens** - 30min for GitHub Actions, 1h for services
- **Separate roles** - Different permissions for different use cases

### Authorization
- **Policy-based access** - Least privilege principle
- **Path restrictions** - Services can only access their required secrets
- **Read-only for services** - Only GitHub Actions can update secrets

### Encryption
- **Transit encryption** - HTTPS API communication
- **Storage encryption** - Secrets encrypted on disk
- **Memory protection** - Secrets cleared from memory

### Auditing
- **Complete audit log** - Every secret access logged
- **Request tracing** - Full request/response audit trail

## Backup & Recovery

### Backup Vault Data
```bash
# Backup Vault data directory
tar -czf vault-backup-$(date +%Y%m%d).tar.gz ${SSD_PATH}/vault/data/

# Export secrets (for migration)
./scripts/export-vault-secrets.sh > vault-secrets-backup.json
```

### Disaster Recovery
1. **Unseal keys** - Keep securely offline
2. **Root token** - Store securely separate from unseal keys
3. **AppRole credentials** - Backup role-id and secret-id files
4. **Data directory** - Regular file system backups

## Monitoring & Maintenance

### Health Checks
```bash
# Check Vault status
vault status

# Check authentication
vault auth -method=userpass username=admin

# Test secret access
vault kv get kv/homeserver/config
```

### Regular Maintenance
- **Rotate AppRole secret-ids** - Monthly
- **Update Vault version** - Follow security updates
- **Audit secret access** - Review logs regularly
- **Test backup/restore** - Quarterly verification

## Troubleshooting

### Common Issues

1. **Vault sealed** - Unseal with 3 keys
2. **Authentication failed** - Check AppRole credentials
3. **Permission denied** - Verify policy permissions
4. **Agent not syncing** - Check agent logs and connectivity

### Debug Commands
```bash
# Check Vault logs
docker logs vault

# Check Agent logs  
docker logs vault-agent

# Test connectivity
curl http://localhost:8200/v1/sys/health

# Validate policies
vault policy read homeserver-policy
```