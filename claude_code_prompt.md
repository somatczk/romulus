# Comprehensive Homeserver Setup - Claude Code Prompt

## Role Definition
You are an expert DevOps engineer and infrastructure architect specializing in production-grade homeserver deployments. You have deep expertise in Docker containerization, networking, security hardening, monitoring systems, and automation. Your approach is methodical, security-conscious, and focused on long-term maintainability. You create robust, well-documented solutions that can operate reliably 24/7 with minimal manual intervention.

## Task Overview
You are tasked with creating a complete, production-ready homeserver infrastructure using Docker. This is a complex, multi-service deployment that requires systematic implementation with careful attention to performance optimization, security hardening, and operational maintainability.

<thinking>
Before starting implementation, I need to:
1. Analyze the hardware specifications and storage architecture requirements
2. Plan the optimal service deployment sequence 
3. Design the network topology and security layers
4. Determine resource allocation strategies
5. Create a comprehensive monitoring and backup strategy
6. Establish the CI/CD pipeline for automated deployments
7. Plan the testing and validation procedures
</thinking>

## Expected Approach
- **Think step-by-step** through each implementation phase
- **Use XML tags** to structure your configurations and documentation
- **Provide detailed examples** for complex configurations
- **Chain your implementation** into logical phases with validation points
- **Include comprehensive testing** procedures for each component
- **Document troubleshooting steps** and common issues
- **Create maintainable, well-commented code** that others can understand and modify

## Hardware Specifications

<hardware_config>
<cpu>AMD 5950x (16 cores/32 threads)</cpu>
<memory>128GB RAM</memory>
<gpu>GTX 1060 Super (for Plex hardware transcoding)</gpu>
<storage_architecture>
  <nvme_drive>
    <capacity>500GB</capacity>
    <purpose>Docker root directory, container images, game server files, configurations</purpose>
    <mount_point>/mnt/nvme</mount_point>
    <optimization>Fastest storage tier - minimize container startup time</optimization>
  </nvme_drive>
  <ssd_drive>
    <capacity>500GB</capacity>
    <purpose>Databases, cache systems, Plex transcoding, active torrents</purpose>
    <mount_point>/mnt/ssd</mount_point>
    <optimization>High IOPS for database operations and frequent access patterns</optimization>
  </ssd_drive>
  <hdd_drive>
    <capacity>1TB</capacity>
    <purpose>Media libraries, completed downloads, backup storage</purpose>
    <mount_point>/mnt/hdd</mount_point>
    <optimization>Bulk sequential storage for large files</optimization>
  </hdd_drive>
</storage_architecture>
<network_config>
  <setup>DMZ configured at router level</setup>
  <domain_management>Cloudflare DNS with API access</domain_management>
  <target_users>5-10 concurrent users maximum</target_users>
</network_config>
</hardware_config>

## Required Services & Performance Specifications

<service_requirements>

<core_infrastructure>
<service name="reverse_proxy">
  <technology>Caddy v2 with automatic HTTPS</technology>
  <features>Cloudflare DNS challenge, HTTP/3 support, automatic certificate renewal</features>
  <resource_allocation>512MB RAM, 1 CPU core</resource_allocation>
  <configuration_priority>Must handle SSL termination for all web services</configuration_priority>
</service>

<service name="dynamic_dns">
  <technology>favonia/cloudflare-ddns container</technology>
  <features>Automatic IP updates, exponential backoff, multi-domain support</features>
  <resource_allocation>64MB RAM, minimal CPU</resource_allocation>
  <update_frequency>Every 5 minutes with failure retry logic</update_frequency>
</service>

<service name="database_primary">
  <technology>MariaDB 10.x for TeamSpeak persistence</technology>
  <features>InnoDB storage engine, connection pooling, automated backups</features>
  <resource_allocation>2GB RAM, 2 CPU cores</resource_allocation>
  <storage_location>/mnt/ssd/databases/mariadb (high IOPS requirement)</storage_location>
</service>

<service name="cache_layer">
  <technology>Redis 7.x for session management</technology>
  <features>Persistent storage, append-only file backup</features>
  <resource_allocation>256MB RAM, 1 CPU core</resource_allocation>
  <storage_location>/mnt/ssd/databases/redis</storage_location>
</service>
</core_infrastructure>

<media_gaming_services>
<service name="plex_media_server">
  <technology>LinuxServer.io Plex image with hardware transcoding</technology>
  <concurrent_users>5-10 simultaneous streams</concurrent_users>
  <resource_allocation>8GB RAM, 6 CPU cores, GPU passthrough</resource_allocation>
  <storage_mapping>
    <metadata>/mnt/ssd/config/plex (frequent access)</metadata>
    <transcoding>/tmp/plex-transcode (tmpfs for performance)</transcoding>
    <media_libraries>/mnt/hdd/media (read-only access)</media_libraries>
  </storage_mapping>
  <hardware_transcoding>NVIDIA NVENC via /dev/dri passthrough</hardware_transcoding>
</service>

<service name="torrent_client">
  <technology>qBittorrent with WebUI via LinuxServer.io</technology>
  <features>Remote management, automatic file organization, ratio enforcement</features>
  <resource_allocation>2GB RAM, 2 CPU cores</resource_allocation>
  <storage_strategy>
    <incomplete_downloads>/mnt/ssd/cache/qbittorrent (active I/O)</incomplete_downloads>
    <completed_downloads>/mnt/hdd/downloads/complete (long-term storage)</completed_downloads>
  </storage_strategy>
  <network_optimization>Port forwarding 6881/TCP+UDP, UPnP disabled</network_optimization>
</service>

<service name="teamspeak_server">
  <technology>Official TeamSpeak 3 server with MariaDB backend</technology>
  <features>Persistent database storage, virtual server management, admin token</features>
  <resource_allocation>1GB RAM, 2 CPU cores</resource_allocation>
  <database_integration>
    <driver>ts3db_mariadb</driver>
    <connection_pooling>enabled with 30-second wait</connection_pooling>
    <automatic_schema_creation>via create_mariadb scripts</automatic_schema_creation>
  </database_integration>
  <network_ports>9987/UDP (voice), 10011/TCP (ServerQuery), 30033/TCP (FileTransfer)</network_ports>
</service>

<service name="cs2_game_server">
  <technology>joedwards32/cs2 Docker image with Steam integration</technology>
  <features>Automatic updates, RCON access, custom game modes, 128-tick server</features>
  <resource_allocation>4GB RAM, 4 CPU cores</resource_allocation>
  <storage_requirements>
    <game_files>/mnt/nvme/games/cs2 (fast loading for maps)</game_files>
    <configuration_persistence>server.cfg, map rotation, admin settings</configuration_persistence>
  </storage_requirements>
  <network_configuration>
    <game_port>27015/TCP+UDP</game_port>
    <rcon_configuration>Secure password, restricted IP access</rcon_configuration>
  </network_configuration>
</service>
</media_gaming_services>

<monitoring_security_services>
<service name="metrics_collection">
  <technology>Prometheus with 30-day retention</technology>
  <targets>Node Exporter, cAdvisor, application metrics, blackbox monitoring</targets>
  <resource_allocation>2GB RAM, 2 CPU cores</resource_allocation>
  <alert_rules>Host down, high resource usage, service failures, backup status</alert_rules>
</service>

<service name="visualization_platform">
  <technology>Grafana with pre-configured dashboards</technology>
  <dashboards>
    <system_monitoring>Node Exporter Full (Dashboard 1860)</system_monitoring>
    <container_monitoring>Docker Container metrics (Dashboard 893)</container_monitoring>
    <homeserver_overview>Custom dashboard for service health</homeserver_overview>
  </dashboards>
  <resource_allocation>1GB RAM, 1 CPU core</resource_allocation>
  <authentication>Admin password, sign-up disabled, domain integration</authentication>
</service>

<service name="log_aggregation">
  <technology>Loki + Promtail for centralized logging</technology>
  <retention_policy>7 days for detailed logs, 30 days for critical events</retention_policy>
  <resource_allocation>1GB RAM (Loki), 256MB RAM (Promtail)</resource_allocation>
  <log_sources>All container logs, system logs, application-specific logs</log_sources>
</service>

<service name="uptime_monitoring">
  <technology>Uptime Kuma for service availability</technology>
  <monitoring_targets>All web services, game servers, database connectivity</monitoring_targets>
  <resource_allocation>512MB RAM, 1 CPU core</resource_allocation>
  <notification_channels>Discord webhooks, email alerts, status page</notification_channels>
</service>

<service name="authentication_gateway">
  <technology>Authelia for single sign-on with 2FA</technology>
  <features>TOTP authentication, session management, access control policies</features>
  <resource_allocation>256MB RAM, 1 CPU core</resource_allocation>
  <backend_storage>SQLite for user database, file-based configuration</backend_storage>
  <integration>Forward auth with Caddy for protected services</integration>
</service>

<service name="intrusion_prevention">
  <technology>Fail2ban with Docker log monitoring</technology>
  <protected_services>SSH, Authelia login, Caddy authentication failures</protected_services>
  <ban_policies>Progressive timeouts: 10min → 1hour → 24hours</ban_policies>
  <integration>iptables rules, notification on ban events</integration>
</service>
</monitoring_security_services>

</service_requirements>

## Implementation Methodology & Best Practices

<implementation_approach>

<step_by_step_process>
**Phase 1: Foundation Setup**
1. System preparation with storage mount configuration
2. Docker installation with optimized daemon configuration
3. Directory structure creation with proper permissions
4. Environment configuration with secure secrets management

**Phase 2: Core Infrastructure Deployment** 
1. Reverse proxy (Caddy) with SSL configuration
2. Dynamic DNS service for domain management
3. Database services (MariaDB, Redis) with persistent storage
4. Network topology with proper segmentation

**Phase 3: Service Layer Implementation**
1. Media services (Plex, qBittorrent) with storage optimization
2. Gaming services (TeamSpeak, CS2) with database integration
3. Service interconnection and dependency management
4. Resource allocation and performance tuning

**Phase 4: Observability & Security**
1. Monitoring stack (Prometheus, Grafana, Loki) deployment
2. Authentication layer (Authelia) with 2FA configuration
3. Security hardening (Fail2ban, network isolation, container security)
4. Health check and alerting system implementation

**Phase 5: Automation & Maintenance**
1. Backup system configuration with cloud storage
2. CI/CD pipeline setup with GitHub Actions
3. Automated update and maintenance procedures
4. Documentation and runbook creation
</step_by_step_process>

<validation_checkpoints>
After each phase, validate:
- All services are running and healthy
- Resource utilization is within expected bounds
- Network connectivity and security policies are correct
- Monitoring and logging are capturing expected data
- Backup and recovery procedures are functional
</validation_checkpoints>

<example_configurations>
**Example: Proper Docker Compose Service Definition**
```yaml
services:
  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    restart: unless-stopped
    networks:
      - frontend
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - VERSION=docker
      - PLEX_CLAIM=${PLEX_CLAIM}
    volumes:
      - ${SSD_PATH}/config/plex:/config
      - ${HDD_PATH}/media:/media:ro
    devices:
      - /dev/dri:/dev/dri
    mem_limit: 8g
    cpus: 6
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:32400/web"]
      interval: 30s
      timeout: 10s
      retries: 3
```

**Example: Security-Hardened Container Configuration**
```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
cap_add:
  - CHOWN
  - SETGID
  - SETUID
read_only: true
tmpfs:
  - /tmp:noexec,nosuid,size=1g
```
</example_configurations>

<troubleshooting_guidance>
**Common Issues and Solutions:**
1. **Container fails to start**: Check volume permissions, environment variables, port conflicts
2. **High resource usage**: Review memory/CPU limits, optimize container configurations
3. **Network connectivity issues**: Verify Docker networks, firewall rules, DNS resolution
4. **SSL certificate failures**: Confirm Cloudflare API tokens, DNS propagation, domain configuration
5. **Database connection errors**: Check service startup order, connection strings, network isolation
</troubleshooting_guidance>

</implementation_approach>

## Expected Deliverables & Output Structure

<deliverable_specifications>

<file_structure>
Create a complete Git repository with this exact structure:
```
homeserver/
├── docker-compose.yml              # Main service definitions
├── docker-compose.override.yml     # Local environment overrides  
├── .env.example                     # Environment template
├── .gitignore                       # Git ignore patterns
├── README.md                        # Comprehensive setup guide
├── configs/                         # Service configurations
│   ├── caddy/
│   │   ├── Caddyfile               # Reverse proxy configuration
│   │   └── docker-compose.yml      # Caddy-specific overrides
│   ├── prometheus/
│   │   ├── prometheus.yml          # Metrics collection config
│   │   ├── alert_rules.yml         # Alerting rules
│   │   └── targets.json            # Service discovery
│   ├── grafana/
│   │   ├── provisioning/           # Auto-provisioned dashboards
│   │   ├── dashboards/             # JSON dashboard definitions
│   │   └── datasources.yml         # Data source configurations
│   ├── authelia/
│   │   ├── configuration.yml       # Authentication configuration
│   │   ├── users_database.yml      # User definitions
│   │   └── policies.yml            # Access control rules
│   ├── loki/
│   │   └── loki.yml                # Log aggregation config
│   └── promtail/
│       └── promtail.yml            # Log collection config
├── scripts/                        # Operational automation
│   ├── deploy.sh                   # Deployment automation
│   ├── backup.sh                   # Backup procedures
│   ├── healthcheck.sh              # Service validation
│   ├── update.sh                   # Container updates
│   └── monitor.sh                  # Resource monitoring
├── .github/
│   └── workflows/
│       ├── deploy.yml              # CI/CD pipeline
│       ├── backup-verify.yml       # Backup validation
│       └── security-scan.yml       # Security scanning
└── docs/                           # Documentation
    ├── architecture.md             # System architecture
    ├── troubleshooting.md          # Common issues
    ├── maintenance.md              # Operational procedures
    └── security.md                 # Security guidelines
```
</file_structure>

<configuration_requirements>
**Each configuration file must include:**
1. **Comprehensive comments** explaining every section and parameter
2. **Security considerations** with explanations of security settings
3. **Performance optimizations** with resource limit justifications  
4. **Dependency relationships** between services clearly documented
5. **Troubleshooting notes** for common configuration issues

**Example: Well-Documented Docker Compose Service**
```yaml
services:
  # TeamSpeak 3 Server with persistent MariaDB backend
  # Requires mariadb service to be healthy before starting
  # Uses SSD storage for optimal database performance
  teamspeak:
    image: teamspeak:latest
    container_name: teamspeak
    restart: unless-stopped
    networks:
      - backend              # Isolated backend network for database access
    ports:
      - "9987:9987/udp"      # Voice communication port
      - "10011:10011"        # ServerQuery port (restrict in production)
      - "30033:30033"        # File transfer port
    environment:
      # Accept TeamSpeak license agreement
      - TS3SERVER_LICENSE=accept
      # Database configuration for persistence
      - TS3SERVER_DB_PLUGIN=ts3db_mariadb
      - TS3SERVER_DB_SQLCREATEPATH=create_mariadb
      - TS3SERVER_DB_HOST=mariadb
      - TS3SERVER_DB_USER=teamspeak
      - TS3SERVER_DB_PASSWORD=${TS3SERVER_DB_PASSWORD}
      - TS3SERVER_DB_NAME=teamspeak
      - TS3SERVER_DB_WAITUNTILREADY=30  # Wait for database initialization
    volumes:
      # Persistent server data and logs on SSD for performance
      - ${SSD_PATH}/config/teamspeak:/var/ts3server
    depends_on:
      mariadb:
        condition: service_healthy    # Ensure database is ready
    # Resource limits prevent TeamSpeak from consuming excessive resources
    mem_limit: 1g                     # Sufficient for 32+ concurrent users  
    cpus: 2                          # Adequate for voice processing
    # Health check ensures service is responding
    healthcheck:
      test: ["CMD", "telnet", "localhost", "10011"]
      interval: 30s
      timeout: 5s
      retries: 3
    # Security hardening
    security_opt:
      - no-new-privileges:true        # Prevent privilege escalation
    cap_drop:
      - ALL                          # Drop all capabilities
    cap_add:
      - CHOWN                        # Only required capabilities
      - SETUID
      - SETGID
```
</configuration_requirements>

<testing_validation_procedures>
**Required Testing Procedures:**
1. **Service Health Validation**
   - Each service must pass health checks
   - Network connectivity between dependent services verified
   - Resource utilization within expected bounds

2. **Security Testing**
   - SSL certificate validity and automatic renewal
   - Authentication flows with 2FA testing
   - Network isolation verification
   - Container security scanning

3. **Performance Validation**
   - Load testing with expected user count
   - Resource monitoring under normal and peak loads
   - Storage I/O performance verification
   - Backup and restore procedure testing

4. **Disaster Recovery Testing**
   - Complete system restoration from backups
   - Service failover and recovery procedures
   - Data integrity verification after recovery

**Example: Comprehensive Health Check Script**
```bash
#!/bin/bash
# healthcheck.sh - Comprehensive service validation

<validation_tests>
SERVICES=(
    "caddy:80:HTTP reverse proxy"
    "plex:32400:Plex Media Server" 
    "qbittorrent:8080:Torrent client WebUI"
    "grafana:3000:Monitoring dashboard"
    "prometheus:9090:Metrics collection"
    "teamspeak:10011:Voice server query"
)

echo "=== Service Health Check ==="
for service_def in "${SERVICES[@]}"; do
    IFS=':' read -r name port description <<< "$service_def"
    if docker exec "$name" nc -z localhost "$port" 2>/dev/null; then
        echo "✅ $description ($name:$port) - Healthy"
    else
        echo "❌ $description ($name:$port) - Failed"
        FAILED_SERVICES+=("$name")
    fi
done

echo "=== External Connectivity Check ==="
EXTERNAL_URLS=(
    "https://plex.yourdomain.com:Plex external access"
    "https://torrents.yourdomain.com:qBittorrent WebUI"
    "https://monitoring.yourdomain.com:Grafana dashboard"
)

for url_def in "${EXTERNAL_URLS[@]}"; do
    IFS=':' read -r url description <<< "$url_def"
    if curl -s -f --connect-timeout 10 "$url" > /dev/null; then
        echo "✅ $description - Accessible"
    else
        echo "❌ $description - Failed"
    fi
done
</validation_tests>
```
</testing_validation_procedures>

</deliverable_specifications>

## Performance & Resource Allocation

### Container Resource Limits
- **Plex**: 8GB RAM, 6 CPU cores (transcoding headroom)
- **Databases**: 2GB RAM each
- **Game Servers**: CS2 4GB RAM, 4 cores; TeamSpeak 1GB RAM, 2 cores
- **Monitoring**: Total 3GB RAM for entire stack
- **Other services**: 512MB-1GB each based on requirements

### Optimization Requirements
- CPU limits to prevent resource monopolization
- Memory limits with swap accounting
- Log rotation to prevent disk space issues
- Tmpfs for temporary directories
- Hardware transcoding configuration for Plex

## Infrastructure as Code Requirements

### Git Repository Structure
```
homeserver/
├── docker-compose.yml
├── docker-compose.override.yml (local overrides)
├── .env (environment variables)
├── .env.example (template)
├── configs/ (service configurations)
│   ├── caddy/
│   ├── prometheus/
│   ├── grafana/
│   ├── authelia/
│   └── loki/
├── scripts/ (deployment, backup, monitoring)
├── .github/workflows/ (CI/CD)
└── README.md (comprehensive documentation)
```

### GitHub Integration Requirements
1. **Self-hosted GitHub Actions runner** for automated deployments
2. **Automated deployment pipeline** triggered on push to main
3. **Health checks** and automatic rollback on failure
4. **Backup creation** before each deployment
5. **Notification integration** (Discord webhook recommended)

## Monitoring & Alerting Specifications

### Metrics Collection
- **System metrics**: CPU, memory, disk, network via Node Exporter
- **Container metrics**: Resource usage, health status via cAdvisor  
- **Application metrics**: Service-specific metrics where available
- **Log aggregation**: All container logs via Promtail to Loki

### Dashboard Requirements
- Import proven community dashboards:
  - Node Exporter Full (Dashboard 1860)
  - Docker Container metrics (Dashboard 893)
  - Custom homeserver overview dashboard

### Alerting Rules
- Host/container down alerts
- High resource usage warnings (>80% CPU/memory/disk)
- Service health check failures
- Failed backup notifications

## Backup Strategy

### Automated Backup Requirements
- **Schedule**: Daily at 2 AM with retention (7 daily, 4 weekly, 12 monthly)
- **Database dumps**: Consistent snapshots before backup
- **Cloud storage**: Backblaze B2 or AWS S3 integration
- **Encryption**: All backups encrypted at rest
- **Verification**: Regular backup integrity checks

### Backup Scope
- All configuration files and Docker Compose definitions
- Database dumps (MariaDB, SQLite databases)
- Critical user data (not media files - too large)
- Application configurations and user settings

## Deployment & Maintenance

### Initial Deployment Process
1. System preparation (storage, Docker installation)
2. Directory structure creation with proper permissions
3. Core services deployment (Caddy, DNS, databases)
4. Service-by-service deployment with validation
5. Monitoring stack configuration
6. Security hardening implementation
7. Backup system configuration and testing

### Ongoing Maintenance Requirements
- **Weekly**: Container updates, resource monitoring, log review
- **Monthly**: Security updates, backup verification, performance review
- **Automated**: Health checks, failover, alerting, backups

## Specific Implementation Requirements

### Service-Specific Configurations

**Plex**:
- Hardware transcoding enabled with GTX 1060
- Metadata on SSD, media on HDD, transcoding on tmpfs
- Proper user/group permissions for media access

**qBittorrent**:
- Web UI configuration with secure authentication
- Download management: incomplete on SSD, complete move to HDD
- Port forwarding and connectivity optimization

**TeamSpeak 3**:
- MariaDB backend with proper connection pooling
- Server admin token management
- Virtual server configuration with proper channels

**CS2 Server**:
- Steam token configuration for server listing
- Game server configuration (tickrate, maps, game modes)
- Log management and RCON access

**Monitoring Stack**:
- Prometheus with 30-day retention
- Grafana with pre-configured dashboards and data sources
- Loki with 7-day log retention
- Alert rules for critical infrastructure monitoring

### Security Hardening Checklist
- [ ] All containers run as non-root users where possible
- [ ] Container capabilities dropped to minimum required
- [ ] Read-only root filesystems implemented where applicable
- [ ] Network segmentation with dedicated Docker networks
- [ ] Secrets management via environment variables
- [ ] Regular security updates automated
- [ ] Fail2ban configured for all exposed services
- [ ] SSL/TLS configuration hardened
- [ ] Authentication required for all admin interfaces

## Success Criteria & Quality Assurance

<success_metrics>

<functional_requirements>
**All services must be:**
1. **Accessible and responsive** via their designated URLs/ports within 30 seconds of deployment
2. **Persistent across restarts** - no data loss during container recreation
3. **Resource-efficient** - total RAM usage under 24GB during normal operation
4. **Monitored and logged** - all services visible in Grafana with appropriate alerts
5. **Secured** - SSL certificates valid, authentication working, fail2ban active
6. **Automated** - deployments, backups, and updates require no manual intervention

<performance_benchmarks>
**System Performance Targets:**
- **Plex**: Support 5+ simultaneous 1080p streams with hardware transcoding
- **qBittorrent**: Handle 50+ active torrents without performance degradation  
- **TeamSpeak**: Support 32+ concurrent voice users with <50ms latency
- **CS2 Server**: Maintain 128-tick performance with 10 players
- **Web Services**: Page load times under 2 seconds on gigabit connection
- **System Resources**: CPU usage <60% average, RAM usage <75% average
</performance_benchmarks>

<security_verification>
**Security Compliance Checklist:**
- [ ] All web services accessible only via HTTPS with valid certificates
- [ ] Authelia 2FA protecting administrative interfaces
- [ ] Container security: non-root users, dropped capabilities, read-only where possible
- [ ] Network segmentation: frontend/backend/monitoring networks isolated
- [ ] Fail2ban monitoring SSH, authentication failures, and application logs
- [ ] Regular security updates automated via CI/CD pipeline
- [ ] Backup encryption verified and restoration tested
- [ ] No sensitive data in environment files or logs
</security_verification>

<operational_readiness>
**Production Readiness Validation:**
- [ ] Complete documentation with troubleshooting procedures
- [ ] Automated deployment pipeline tested and verified
- [ ] Backup and restoration procedures validated with actual data
- [ ] Monitoring dashboards configured with appropriate alert thresholds
- [ ] Health checks functional for all critical services
- [ ] Resource limits properly configured to prevent resource exhaustion
- [ ] Log rotation and retention policies implemented
- [ ] Update procedures tested without service interruption
</operational_readiness>
</functional_requirements>

</success_metrics>

<quality_standards>

<code_quality_requirements>
**All configuration files must:**
1. **Include comprehensive comments** explaining purpose, dependencies, and configuration rationale
2. **Use consistent formatting** with proper indentation and structure
3. **Implement error handling** for common failure scenarios
4. **Include validation steps** to verify correct configuration
5. **Document security considerations** for each service and setting

**Example: High-Quality Configuration Header**
```yaml
# Prometheus Configuration - Metrics Collection and Monitoring
# 
# Purpose: Collects metrics from all homeserver services for monitoring and alerting
# Dependencies: Node Exporter, cAdvisor, and service-specific exporters must be running
# Storage: 30-day retention with 15-second collection intervals
# Security: Basic auth required for external access, internal network only
# Performance: Configured for up to 50 targets with moderate query load
#
# Troubleshooting:
# - If targets are down, check Docker networking and service health
# - High memory usage may require increasing retention settings
# - Certificate errors indicate Cloudflare DNS challenge issues
#
# Last updated: 2024-01-15
# Contact: admin@yourdomain.com for configuration changes

global:
  scrape_interval: 15s          # Balance between data granularity and resource usage
  evaluation_interval: 15s      # How frequently to evaluate alert rules
  external_labels:              # Labels added to all metrics for identification
    environment: 'homeserver'
    instance: 'primary'
```
</code_quality_requirements>

<documentation_standards>
**Documentation must include:**
1. **Architecture diagrams** showing service relationships and data flows
2. **Step-by-step procedures** for common operational tasks
3. **Troubleshooting guides** with specific symptoms and solutions
4. **Security guidelines** for ongoing maintenance and updates
5. **Performance tuning** recommendations based on usage patterns

**Example: Troubleshooting Entry Format**
```markdown
### Problem: Plex Server Not Accessible Externally

**Symptoms:**
- Plex works on local network (192.168.x.x) but not via plex.yourdomain.com
- SSL certificate shows as valid in browser
- Other web services (Grafana, qBittorrent) work correctly

**Diagnosis Steps:**
1. Check Caddy reverse proxy logs: `docker logs caddy | grep plex`
2. Verify Plex container is running: `docker ps | grep plex`
3. Test internal connectivity: `docker exec caddy curl -I http://plex:32400`
4. Check DNS resolution: `nslookup plex.yourdomain.com`

**Common Causes & Solutions:**
- **Plex container not in frontend network**: Add to docker-compose networks section
- **Plex not claiming server**: Verify PLEX_CLAIM token is valid and not expired
- **Firewall blocking port 32400**: Add UFW rule or check router DMZ configuration
- **DNS not propagated**: Wait up to 48 hours or flush DNS cache

**Prevention:**
- Monitor Plex health check endpoint in Uptime Kuma
- Set up alert for Plex container restart events
- Document any custom Plex configuration changes
```
</documentation_standards>

</quality_standards>

<final_validation_checklist>

**Before considering the implementation complete, verify:**

<system_validation>
- [ ] All 15+ services running and passing health checks
- [ ] External access working for all web services (plex.domain.com, etc.)
- [ ] TeamSpeak server accessible and database persistence working
- [ ] CS2 server joinable and maintaining stable 128-tick performance
- [ ] Monitoring dashboards populated with live data from all services
- [ ] Backup system creating and verifying encrypted cloud backups daily
- [ ] GitHub Actions pipeline deploying changes automatically on push
- [ ] Resource utilization graphs showing system operating within limits
</system_validation>

<user_experience_validation>
- [ ] Plex: Media playback smooth with hardware transcoding active
- [ ] qBittorrent: Torrents downloading/seeding with proper organization
- [ ] TeamSpeak: Voice quality clear with persistent user permissions
- [ ] CS2: Game server stable with admin access and custom configurations
- [ ] Grafana: Dashboards intuitive with relevant metrics easily accessible
- [ ] Authelia: 2FA login working smoothly across all protected services
</user_experience_validation>

<operational_validation>
- [ ] Complete system restoration tested from backup (data integrity verified)
- [ ] Individual service restart tested (no cascading failures)
- [ ] Update process tested (zero-downtime deployment confirmed)
- [ ] Alert system tested (notifications received for simulated failures)
- [ ] Documentation verified by following procedures as written
- [ ] Security scan completed with no critical vulnerabilities
</operational_validation>

</final_validation_checklist>

## Implementation Instructions

<final_instructions>
**Create this infrastructure systematically using the following approach:**

1. **Start with detailed planning** - analyze requirements and create implementation timeline
2. **Implement in phases** - validate each phase before proceeding to prevent cascading issues
3. **Use extensive examples** - provide 3-5 working configuration examples for complex services
4. **Think step-by-step** - break down complex configurations into logical components
5. **Include comprehensive testing** - validate each service individually and as part of the system
6. **Document everything** - create maintainable documentation that others can follow
7. **Focus on production readiness** - implement proper monitoring, backup, and security from the start

**Remember:** This system must operate reliably 24/7 with minimal manual intervention. Prioritize robustness, security, and maintainability over complexity or cutting-edge features. Every configuration should be explainable, testable, and recoverable.
</final_instructions>