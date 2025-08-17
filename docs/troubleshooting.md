# Troubleshooting Guide

Comprehensive troubleshooting guide for homeserver infrastructure issues.

## General Troubleshooting Approach

### 1. Information Gathering

```bash
# Check overall system health
./scripts/healthcheck.sh --verbose

# Check service status
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml ps

# Check system resources
df -h
free -h
top

# Check recent logs
journalctl -u docker.service --since "1 hour ago"
```

### 2. Service-Specific Logs

```bash
# View logs for specific service
docker-compose logs [service_name]

# Follow logs in real-time
docker-compose logs -f [service_name]

# View last 100 lines
docker-compose logs --tail=100 [service_name]
```

## Service-Specific Issues

### Caddy Reverse Proxy

#### Problem: SSL Certificate Issues

**Symptoms:**
- HTTPS sites showing certificate errors
- "Certificate not valid" messages
- Services accessible via HTTP but not HTTPS

**Diagnosis:**
```bash
# Check Caddy logs
docker-compose logs caddy | grep -i "cert\|ssl\|acme"

# Check Cloudflare API access
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
     -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
     -H "Content-Type: application/json"

# Verify DNS propagation
dig TXT _acme-challenge.yourdomain.com
```

**Solutions:**
1. **Invalid Cloudflare API Token**:
   ```bash
   # Regenerate Cloudflare API token with proper permissions:
   # Zone:Zone:Read, Zone:DNS:Edit
   ```

2. **DNS Propagation Issues**:
   ```bash
   # Wait for DNS propagation (up to 48 hours)
   # Check multiple DNS servers:
   nslookup yourdomain.com 8.8.8.8
   nslookup yourdomain.com 1.1.1.1
   ```

3. **Rate Limiting**:
   ```bash
   # Let's Encrypt rate limits - wait and retry
   # Check Caddy logs for rate limit messages
   ```

#### Problem: Reverse Proxy Not Working

**Symptoms:**
- 502 Bad Gateway errors
- Services not accessible via domain names
- Direct IP access works but domain access fails

**Diagnosis:**
```bash
# Test internal connectivity
docker exec caddy nc -z plex 32400
docker exec caddy nc -z grafana 3000

# Check Docker networks
docker network ls
docker network inspect homeserver_frontend
```

**Solutions:**
1. **Service Network Issues**:
   ```bash
   # Ensure services are on correct networks
   # Check docker-compose.yml network configuration
   docker-compose down && docker-compose up -d
   ```

2. **Firewall Blocking**:
   ```bash
   # Check UFW status
   sudo ufw status
   
   # Ensure ports 80 and 443 are open
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   ```

### Plex Media Server

#### Problem: Hardware Transcoding Not Working

**Symptoms:**
- High CPU usage during transcoding
- "Hardware transcoding unavailable" in settings
- Transcoding slower than expected

**Diagnosis:**
```bash
# Check GPU availability in container
docker exec plex nvidia-smi

# Check Plex logs for transcoding messages
docker-compose logs plex | grep -i "transcode\|hardware"

# Verify GPU passthrough
docker exec plex ls -la /dev/dri/
```

**Solutions:**
1. **GPU Not Accessible**:
   ```bash
   # Install NVIDIA Docker runtime
   sudo apt install nvidia-docker2
   sudo systemctl restart docker
   
   # Add GPU to docker-compose.yml:
   # runtime: nvidia
   # environment:
   #   - NVIDIA_VISIBLE_DEVICES=all
   ```

2. **Driver Issues**:
   ```bash
   # Check NVIDIA driver
   nvidia-smi
   
   # Update drivers if needed
   sudo apt update && sudo apt upgrade nvidia-driver-*
   ```

#### Problem: Plex Server Not Accessible Externally

**Symptoms:**
- Plex works on local network but not via plex.yourdomain.com
- "Server is not powerful enough" errors
- Connection timeout errors

**Diagnosis:**
```bash
# Check Plex service status
docker-compose ps plex

# Test internal connectivity
curl -I http://plex:32400

# Check DNS resolution
nslookup plex.yourdomain.com
```

**Solutions:**
1. **Plex Claim Token Expired**:
   ```bash
   # Get new claim token from https://plex.tv/claim
   # Update .env file and restart:
   docker-compose restart plex
   ```

2. **Network Configuration**:
   ```bash
   # Check Plex network settings
   # Ensure "Enable Remote Access" is checked
   # Verify port mapping in docker-compose.yml
   ```

### Database Issues

#### Problem: MariaDB Connection Failures

**Symptoms:**
- Services can't connect to database
- "Connection refused" or "Access denied" errors
- Database service keeps restarting

**Diagnosis:**
```bash
# Check MariaDB status
docker-compose ps mariadb

# Test database connectivity
docker exec mariadb mysqladmin ping -u root -p$MYSQL_ROOT_PASSWORD

# Check database logs
docker-compose logs mariadb
```

**Solutions:**
1. **Password Issues**:
   ```bash
   # Reset root password (WARNING: This will reset all data)
   docker-compose down
   docker volume rm homeserver_mariadb_data
   docker-compose up -d mariadb
   ```

2. **Disk Space**:
   ```bash
   # Check available disk space
   df -h /mnt/ssd
   
   # Clean up old logs if needed
   docker-compose exec mariadb mysql -u root -p$MYSQL_ROOT_PASSWORD -e "PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 7 DAY);"
   ```

#### Problem: Redis Connection Issues

**Symptoms:**
- "Connection to Redis failed" messages
- Session management not working
- High memory usage

**Diagnosis:**
```bash
# Test Redis connectivity
docker exec redis redis-cli --no-auth-warning -a $REDIS_PASSWORD ping

# Check Redis memory usage
docker exec redis redis-cli --no-auth-warning -a $REDIS_PASSWORD info memory

# Monitor Redis commands
docker exec redis redis-cli --no-auth-warning -a $REDIS_PASSWORD monitor
```

**Solutions:**
1. **Memory Limits**:
   ```bash
   # Check Redis configuration
   docker exec redis redis-cli --no-auth-warning -a $REDIS_PASSWORD config get maxmemory
   
   # Increase memory limit in docker-compose.yml if needed
   ```

2. **Persistence Issues**:
   ```bash
   # Force Redis save
   docker exec redis redis-cli --no-auth-warning -a $REDIS_PASSWORD bgsave
   
   # Check save status
   docker exec redis redis-cli --no-auth-warning -a $REDIS_PASSWORD lastsave
   ```

### Gaming Services

#### Problem: TeamSpeak Server Won't Start

**Symptoms:**
- TeamSpeak container exits immediately
- "Database connection failed" errors
- No admin token generated

**Diagnosis:**
```bash
# Check TeamSpeak logs
docker-compose logs teamspeak

# Verify MariaDB is running
docker-compose ps mariadb

# Test database connection from TeamSpeak container
docker exec teamspeak nc -z mariadb 3306
```

**Solutions:**
1. **Database Connection**:
   ```bash
   # Wait for MariaDB to be fully ready
   docker-compose up -d mariadb
   sleep 30
   docker-compose up -d teamspeak
   ```

2. **License Agreement**:
   ```bash
   # Ensure license is accepted in environment:
   # TS3SERVER_LICENSE=accept
   ```

#### Problem: CS2 Server Not Joinable

**Symptoms:**
- Server not appearing in server browser
- "Server not responding" when trying to connect
- Connection timeout errors

**Diagnosis:**
```bash
# Check CS2 server status
docker-compose logs cs2-server

# Test port connectivity
nc -z localhost 27015
nc -z yourdomain.com 27015

# Check Steam token
docker-compose logs cs2-server | grep -i "token"
```

**Solutions:**
1. **Steam Token Issues**:
   ```bash
   # Get valid Steam token from https://steamcommunity.com/dev/managegameservers
   # Update STEAM_TOKEN in .env
   docker-compose restart cs2-server
   ```

2. **Port Forwarding**:
   ```bash
   # Ensure ports are forwarded on router:
   # 27015 TCP/UDP for game traffic
   # 27025 TCP for RCON (optional)
   ```

### Monitoring Stack Issues

#### Problem: Prometheus Not Scraping Targets

**Symptoms:**
- Targets showing as "DOWN" in Prometheus
- Missing metrics in Grafana dashboards
- "No data" messages in graphs

**Diagnosis:**
```bash
# Check Prometheus targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health != "up")'

# Check network connectivity
docker exec prometheus nc -z node-exporter 9100
docker exec prometheus nc -z cadvisor 8080

# Verify service discovery
docker-compose logs prometheus | grep -i "discovery\|target"
```

**Solutions:**
1. **Network Configuration**:
   ```bash
   # Ensure all services are on monitoring network
   # Check docker-compose network configuration
   docker network inspect homeserver_monitoring
   ```

2. **Service Endpoints**:
   ```bash
   # Verify endpoints are accessible
   curl http://localhost:9100/metrics  # Node Exporter
   curl http://localhost:8080/metrics  # cAdvisor
   ```

#### Problem: Grafana Dashboards Not Loading

**Symptoms:**
- Blank or error messages in Grafana
- "Data source not found" errors
- Dashboards showing "No data"

**Diagnosis:**
```bash
# Check Grafana logs
docker-compose logs grafana

# Test Prometheus connectivity from Grafana
docker exec grafana nc -z prometheus 9090

# Check data source configuration
curl -s -u admin:$GF_SECURITY_ADMIN_PASSWORD http://localhost:3000/api/datasources
```

**Solutions:**
1. **Data Source Configuration**:
   ```bash
   # Verify Prometheus URL in Grafana data sources
   # Should be: http://prometheus:9090
   ```

2. **Dashboard Import**:
   ```bash
   # Re-import dashboards if needed
   # Use dashboard IDs: 1860 (Node Exporter), 893 (Docker)
   ```

### Security Service Issues

#### Problem: Authelia Authentication Not Working

**Symptoms:**
- Can't access protected services
- "Authentication failed" messages
- 2FA setup not working

**Diagnosis:**
```bash
# Check Authelia logs
docker-compose logs authelia

# Test Authelia health endpoint
curl http://localhost:9091/api/health

# Verify Redis connectivity
docker exec authelia nc -z redis 6379
```

**Solutions:**
1. **Configuration Issues**:
   ```bash
   # Validate Authelia configuration
   docker exec authelia authelia validate-config /config/configuration.yml
   ```

2. **Password Hash Format**:
   ```bash
   # Generate proper password hash
   docker run --rm authelia/authelia:latest authelia hash-password 'your_password'
   
   # Update users_database.yml with new hash
   ```

#### Problem: Fail2ban Not Blocking IPs

**Symptoms:**
- Brute force attacks not being blocked
- No banned IPs in fail2ban logs
- Suspicious activity continuing

**Diagnosis:**
```bash
# Check fail2ban status
docker exec fail2ban fail2ban-client status

# Check jail status
docker exec fail2ban fail2ban-client status sshd

# View banned IPs
docker exec fail2ban fail2ban-client banned
```

**Solutions:**
1. **Log File Access**:
   ```bash
   # Ensure log files are accessible
   # Check volume mounts in docker-compose.yml
   ls -la /var/log/auth.log
   ```

2. **Filter Configuration**:
   ```bash
   # Test fail2ban filters
   docker exec fail2ban fail2ban-regex /var/log/auth.log /etc/fail2ban/filter.d/sshd.conf
   ```

## Performance Issues

### High CPU Usage

**Diagnosis:**
```bash
# Identify high CPU processes
top -p $(docker inspect --format='{{.State.Pid}}' $(docker ps -q))

# Check container resource usage
docker stats

# Monitor system load
uptime
iostat 1 5
```

**Solutions:**
1. **Container Resource Limits**:
   ```bash
   # Add CPU limits to docker-compose.yml:
   # cpus: 2.0
   # mem_limit: 4g
   ```

2. **Service Optimization**:
   ```bash
   # Plex: Enable hardware transcoding
   # Prometheus: Reduce scrape frequency
   # Databases: Optimize queries and indexes
   ```

### High Memory Usage

**Diagnosis:**
```bash
# Check system memory usage
free -h

# Identify memory-hungry containers
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"

# Check for memory leaks
for container in $(docker ps --format '{{.Names}}'); do
    echo "=== $container ==="
    docker exec $container ps aux --sort=-pmem | head -5
done
```

**Solutions:**
1. **Memory Limits**:
   ```bash
   # Set appropriate memory limits in docker-compose.yml
   # Monitor with: docker stats
   ```

2. **Database Optimization**:
   ```bash
   # MariaDB: Adjust buffer pool size
   # Redis: Set maxmemory and eviction policy
   # Prometheus: Reduce retention time
   ```

### Disk Space Issues

**Diagnosis:**
```bash
# Check disk usage by mount point
df -h /mnt/*

# Find largest files and directories
du -sh /mnt/ssd/* | sort -hr | head -10
du -sh /mnt/hdd/* | sort -hr | head -10

# Check Docker disk usage
docker system df
```

**Solutions:**
1. **Log Rotation**:
   ```bash
   # Configure log rotation
   sudo logrotate -f /etc/logrotate.conf
   
   # Clean Docker logs
   docker system prune -f
   ```

2. **Data Cleanup**:
   ```bash
   # Clean old Prometheus data
   # Clean old backup files
   # Move large media files to HDD storage
   ```

## Network Issues

### DNS Resolution Problems

**Diagnosis:**
```bash
# Test DNS resolution
nslookup yourdomain.com
dig yourdomain.com A
dig yourdomain.com AAAA

# Check local DNS
cat /etc/resolv.conf

# Test from containers
docker exec caddy nslookup yourdomain.com
```

**Solutions:**
1. **DNS Configuration**:
   ```bash
   # Update DNS servers
   echo "nameserver 1.1.1.1" >> /etc/resolv.conf
   echo "nameserver 8.8.8.8" >> /etc/resolv.conf
   ```

2. **Docker DNS**:
   ```bash
   # Configure Docker daemon DNS
   # Edit /etc/docker/daemon.json:
   # {"dns": ["1.1.1.1", "8.8.8.8"]}
   sudo systemctl restart docker
   ```

### Port Conflicts

**Diagnosis:**
```bash
# Check port usage
netstat -tulpn | grep LISTEN
ss -tulpn | grep LISTEN

# Check Docker port mappings
docker port $(docker ps -q)
```

**Solutions:**
1. **Change Port Mappings**:
   ```bash
   # Update port mappings in docker-compose.yml
   # Ensure no conflicts with host services
   ```

2. **Service Conflicts**:
   ```bash
   # Stop conflicting services
   sudo systemctl stop apache2  # If running
   sudo systemctl stop nginx    # If running
   ```

## Emergency Procedures

### Complete System Recovery

```bash
# 1. Stop all services
docker-compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.security.yml down

# 2. Backup current state
./scripts/backup.sh --type full

# 3. Reset Docker environment
docker system prune -a --volumes

# 4. Restore from backup
# (Implement restore procedures based on your backup strategy)

# 5. Redeploy infrastructure
./scripts/deploy.sh
```

### Service-Specific Recovery

```bash
# Reset individual service
docker-compose stop [service_name]
docker-compose rm [service_name]
docker volume rm homeserver_[service_name]_data  # If needed
docker-compose up -d [service_name]
```

### Log Collection for Support

```bash
# Collect comprehensive logs
mkdir -p /tmp/homeserver-logs
docker-compose logs > /tmp/homeserver-logs/docker-compose.log
journalctl -u docker.service --since "24 hours ago" > /tmp/homeserver-logs/docker-service.log
./scripts/healthcheck.sh --json > /tmp/homeserver-logs/health-check.json
docker system df > /tmp/homeserver-logs/docker-system.txt
free -h > /tmp/homeserver-logs/memory.txt
df -h > /tmp/homeserver-logs/disk.txt

# Create archive
tar -czf /tmp/homeserver-logs-$(date +%Y%m%d-%H%M%S).tar.gz -C /tmp homeserver-logs/
```

## Getting Additional Help

### Community Resources

- **Docker Community**: https://community.docker.com/
- **Plex Forums**: https://forums.plex.tv/
- **TeamSpeak Support**: https://support.teamspeak.com/
- **Grafana Community**: https://community.grafana.com/
- **Reddit**: r/selfhosted, r/homelab

### Professional Support

If issues persist after following this troubleshooting guide:

1. **Collect logs** using the log collection procedure above
2. **Document the issue** with symptoms, steps to reproduce, and environment details
3. **Check service-specific documentation** for advanced troubleshooting
4. **Consider professional consultation** for complex infrastructure issues

Remember to always backup your data before making significant changes to your infrastructure.