# Automated Domain Management Scripts

This directory contains scripts for automatically managing DNS records based on your Caddy configuration.

## Overview

The CloudFlare DDNS service automatically updates DNS records for all subdomains configured in your Caddyfile. This ensures that any new services you add are automatically accessible via HTTPS with valid SSL certificates.

## How It Works

1. **Caddyfile Parsing**: The system reads your `configs/caddy/Caddyfile` to discover all configured subdomains
2. **Domain Extraction**: Extracts patterns like `subdomain.{env.DOMAIN}` 
3. **DNS Updates**: Updates CloudFlare DNS records for all discovered domains
4. **Automatic Updates**: Runs every 5 minutes to detect IP changes

## Currently Discovered Subdomains

Based on your Caddyfile, these subdomains are automatically managed:

- `plex.{DOMAIN}` - Plex Media Server
- `torrents.{DOMAIN}` - qBittorrent WebUI  
- `monitoring.{DOMAIN}` - Grafana Dashboard
- `metrics.{DOMAIN}` - Prometheus Metrics (protected)
- `status.{DOMAIN}` - Uptime Kuma Status Page
- `health.{DOMAIN}` - Health Check Endpoint

## Configuration

### Environment Variables

Set these in your `.env` file or GitHub Secrets:

```bash
DOMAIN=yourdomain.com
CLOUDFLARE_API_TOKEN=your_api_token_here

# Optional: Override auto-discovered domains
CLOUDFLARE_DOMAINS=yourdomain.com,plex.yourdomain.com,torrents.yourdomain.com,monitoring.yourdomain.com
```

### GitHub Secrets Required

- `CLOUDFLARE_API_TOKEN` - CloudFlare API token with DNS edit permissions
- `CLOUDFLARE_DOMAINS` - (Optional) Override auto-discovered domain list

## Manual Domain Discovery

Use the `sync-domains.sh` script to manually extract domains:

```bash
# Run domain discovery
./configs/scripts/sync-domains.sh

# View discovered domains
cat /tmp/domains.env
```

## Adding New Subdomains

1. Add new subdomain configuration to `configs/caddy/Caddyfile`:
   ```
   newservice.{env.DOMAIN} {
       reverse_proxy newservice:8080
   }
   ```

2. The CloudFlare DDNS service will automatically detect and update DNS records

3. SSL certificates will be automatically provisioned by Caddy

## Troubleshooting

### Check Current Domains
```bash
docker logs cloudflare-ddns
```

### Verify Caddyfile Syntax
```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

### Manual DNS Update
```bash
# Restart the DDNS service to force update
docker-compose -f compose/core/proxy.yml restart cloudflare-ddns
```

## Benefits

✅ **Automatic Discovery** - New subdomains are automatically detected  
✅ **Zero Configuration** - Works out of the box with your Caddyfile  
✅ **SSL Certificates** - Automatic HTTPS with Let's Encrypt  
✅ **IP Updates** - Keeps DNS records current with dynamic IPs  
✅ **CloudFlare Integration** - Uses CloudFlare proxy for DDoS protection