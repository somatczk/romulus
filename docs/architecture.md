# System Architecture

Comprehensive architecture documentation for the homeserver infrastructure.

## Overview

The homeserver infrastructure is designed as a containerized, microservices-based system optimized for high availability, security, and performance. It supports media streaming, gaming services, monitoring, and automation while maintaining production-grade reliability.

## Architecture Principles

### Design Goals

- **High Availability**: Services designed to run 24/7 with minimal downtime
- **Security First**: Multiple layers of security including network isolation, authentication, and encryption
- **Performance Optimized**: Hardware-accelerated where possible, tiered storage strategy
- **Maintainable**: Infrastructure as Code with automated deployment and monitoring
- **Scalable**: Modular design allowing for easy service addition/removal

### Core Concepts

- **Containerization**: All services run in Docker containers for isolation and portability
- **Network Segmentation**: Isolated networks for different service tiers
- **Storage Tiers**: NVMe/SSD/HDD tiering based on access patterns
- **Observability**: Comprehensive monitoring, logging, and alerting
- **Automation**: Automated deployment, backups, and maintenance

## System Components

### Infrastructure Layer

```
┌─────────────────────────────────────────────────────────────┐
│                    Infrastructure Layer                      │
├─────────────────────────────────────────────────────────────┤
│  Host OS: Ubuntu 20.04 LTS                                 │
│  Container Runtime: Docker 20.10+                          │
│  Orchestration: Docker Compose                             │
│  Storage: NVMe (500GB) + SSD (500GB) + HDD (1TB)         │
│  Network: DMZ/Port Forwarding + Cloudflare DNS            │
└─────────────────────────────────────────────────────────────┘
```

### Network Architecture

```
                    Internet
                       │
                 [Cloudflare DNS]
                       │
                 [Router/Firewall]
                       │
              ┌────────┴────────┐
              │   Docker Host   │
              │                 │
    ┌─────────┼─────────────────┼─────────┐
    │         │                 │         │
┌───▼───┐ ┌──▼───┐         ┌───▼────┐ ┌──▼────┐
│Frontend│ │Backend│       │Monitoring│ │ Host  │
│Network │ │Network│       │ Network  │ │Network│
│        │ │       │       │          │ │       │
│ Caddy  │ │MariaDB│       │Prometheus│ │SSH/GUI│
│ Plex   │ │ Redis │       │ Grafana  │ │       │
│qBittorr│ │       │       │   Loki   │ │       │
│TeamSp. │ │       │       │          │ │       │
│CS2     │ │       │       │          │ │       │
└────────┘ └───────┘       └──────────┘ └───────┘
```

### Service Tiers

#### Tier 1: Core Infrastructure
- **Caddy**: Reverse proxy and SSL termination
- **MariaDB**: Primary relational database
- **Redis**: Session storage and caching
- **Cloudflare DDNS**: Dynamic DNS management

#### Tier 2: Application Services
- **Plex Media Server**: Media streaming with hardware transcoding
- **qBittorrent**: Torrent client and download management
- **TeamSpeak 3**: Voice communication server
- **Counter-Strike 2**: Game server

#### Tier 3: Observability
- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **Loki**: Log aggregation
- **Promtail**: Log collection agent
- **Uptime Kuma**: Service availability monitoring

#### Tier 4: Security
- **Authelia**: Single sign-on and 2FA
- **Fail2ban**: Intrusion prevention
- **Security monitoring**: Custom security event collection

## Data Flow Architecture

### Request Flow

```
User Request → Cloudflare → Router → Caddy → Service
                    ↓
              SSL Termination
                    ↓
            Authentication (Authelia)
                    ↓
              Service Response
```

### Detailed Request Processing

1. **DNS Resolution**: Cloudflare resolves subdomain to external IP
2. **SSL Termination**: Caddy handles HTTPS and certificate management
3. **Authentication**: Authelia validates user credentials (if required)
4. **Reverse Proxy**: Caddy forwards request to appropriate service
5. **Service Processing**: Target service processes the request
6. **Response**: Response flows back through the same path

### Monitoring Data Flow

```
Services → Exporters → Prometheus → Grafana
    │                       ↓
    └────→ Logs → Promtail → Loki → Grafana
                                      ↓
                              Alertmanager → Notifications
```

## Storage Architecture

### Storage Tier Strategy

```
┌─────────────────┬─────────────────┬─────────────────┐
│   NVMe (500GB)  │   SSD (500GB)   │   HDD (1TB+)    │
├─────────────────┼─────────────────┼─────────────────┤
│ Docker Root     │ Databases       │ Media Libraries │
│ Container Images│ Active Downloads│ Completed Files │
│ Game Server Data│ Config Files    │ Backup Archives │
│ Temp Files      │ Log Files       │ Cold Storage    │
│ Cache           │ Metrics Data    │                 │
└─────────────────┴─────────────────┴─────────────────┘
```

### Storage Mapping

| Path | Storage | Purpose | Access Pattern |
|------|---------|---------|----------------|
| `/var/lib/docker` | NVMe | Docker root | High I/O |
| `/mnt/nvme/games` | NVMe | Game data | Fast access |
| `/mnt/ssd/databases` | SSD | Database storage | High IOPS |
| `/mnt/ssd/config` | SSD | Application configs | Frequent reads |
| `/mnt/ssd/monitoring` | SSD | Metrics/logs | Write-heavy |
| `/mnt/hdd/media` | HDD | Media libraries | Sequential reads |
| `/mnt/hdd/downloads` | HDD | Completed downloads | Bulk storage |

## Security Architecture

### Defense in Depth

```
┌────────────────────────────────────────────────────────────┐
│                     Security Layers                        │
├────────────────────────────────────────────────────────────┤
│ 1. Network Perimeter: Firewall + DMZ                      │
│ 2. DNS Security: Cloudflare with DDoS protection          │
│ 3. Transport Security: TLS 1.3 with automatic certificates│
│ 4. Application Security: Authelia 2FA + RBAC              │
│ 5. Container Security: Non-root users + dropped caps      │
│ 6. Network Isolation: Segmented Docker networks           │
│ 7. Intrusion Detection: Fail2ban with automated blocking  │
│ 8. Data Security: Encryption at rest and in transit       │
└────────────────────────────────────────────────────────────┘
```

### Network Security Model

- **Frontend Network**: Public-facing services with reverse proxy access
- **Backend Network**: Internal services, no direct external access
- **Monitoring Network**: Observability services, isolated from production
- **Host Network**: Direct host access for specific services only

### Authentication Flow

```
User → Authelia → 2FA Check → Authorization → Service Access
  │                               │
  └─ Session Storage (Redis) ─────┘
```

## Monitoring Architecture

### Observability Stack

```
                    Visualization
                   ┌─────────────┐
                   │   Grafana   │
                   └─────┬───────┘
                         │
            ┌────────────┼────────────┐
            │            │            │
        ┌───▼───┐   ┌────▼────┐   ┌───▼────┐
        │ Loki  │   │Prometheus│   │Uptime  │
        │ (logs)│   │(metrics) │   │ Kuma   │
        └───▲───┘   └────▲────┘   └────────┘
            │            │
        ┌───▼───┐   ┌────▼────┐
        │Promtail│   │Exporters│
        └───────┘   └─────────┘
            │            │
        ┌───▼────────────▼───┐
        │    Services        │
        └────────────────────┘
```

### Metrics Collection

- **System Metrics**: Node Exporter (CPU, memory, disk, network)
- **Container Metrics**: cAdvisor (Docker container resources)
- **Application Metrics**: Service-specific exporters
- **Custom Metrics**: Application performance indicators

### Log Aggregation

- **Container Logs**: Docker logging driver → Promtail → Loki
- **System Logs**: Journald → Promtail → Loki
- **Application Logs**: File-based → Promtail → Loki
- **Security Logs**: Fail2ban, auth logs → Promtail → Loki

## Deployment Architecture

### CI/CD Pipeline

```
Git Push → GitHub Actions → Validation → Backup → Deploy → Health Check
                                                      ↓
                                               Success/Failure
                                                      ↓
                                              Notification
```

### Deployment Stages

1. **Validation**: Configuration syntax, Docker Compose validation
2. **Pre-deployment Backup**: Automated backup of critical data
3. **Image Pull**: Latest container images from registries
4. **Service Deployment**: Rolling deployment with health checks
5. **Post-deployment Validation**: Comprehensive health checks
6. **Notification**: Success/failure notifications via Discord/email

### Infrastructure as Code

```
Repository Structure:
├── docker-compose.yml          # Core services
├── docker-compose.monitoring.yml # Observability stack
├── docker-compose.security.yml   # Security services
├── configs/                    # Service configurations
├── scripts/                    # Automation scripts
└── .github/workflows/         # CI/CD pipelines
```

## Performance Architecture

### Resource Allocation

| Service | CPU Cores | RAM | Storage | Priority |
|---------|-----------|-----|---------|----------|
| Plex | 6 | 8GB | NVMe/HDD | High |
| CS2 Server | 4 | 4GB | NVMe | High |
| MariaDB | 2 | 2GB | SSD | Critical |
| Redis | 1 | 256MB | SSD | Critical |
| Prometheus | 2 | 2GB | SSD | Medium |
| Grafana | 1 | 1GB | SSD | Medium |
| Others | 1 | 512MB | SSD | Low |

### Performance Optimizations

- **Hardware Transcoding**: NVIDIA GPU for Plex media transcoding
- **Database Optimization**: InnoDB tuning for MariaDB, Redis memory policies
- **Storage Tiering**: Hot data on NVMe/SSD, cold data on HDD
- **Network Optimization**: HTTP/2, gzip compression, CDN integration
- **Container Optimization**: Resource limits, health checks, restart policies

## Disaster Recovery Architecture

### Backup Strategy

```
┌─────────────────┬─────────────────┬─────────────────┐
│   Local Backup  │  Cloud Backup   │   Data Types    │
├─────────────────┼─────────────────┼─────────────────┤
│ SSD Storage     │ Backblaze B2    │ Database Dumps  │
│ Automated Daily │ Encrypted       │ Configurations  │
│ 30-day Retention│ 90-day Retention│ SSL Certificates│
│                 │                 │ User Data       │
└─────────────────┴─────────────────┴─────────────────┘
```

### Recovery Procedures

1. **Service Recovery**: Restart individual services with health checks
2. **Configuration Recovery**: Restore from Git repository
3. **Data Recovery**: Restore encrypted backups from cloud storage
4. **Complete Rebuild**: Full infrastructure recreation from backups

## Scalability Considerations

### Horizontal Scaling Options

- **Load Balancing**: Multiple Caddy instances behind load balancer
- **Database Clustering**: MariaDB Galera cluster for high availability
- **Service Replication**: Multiple instances of stateless services
- **Storage Scaling**: Additional storage tiers, network attached storage

### Vertical Scaling Limits

- **CPU**: Currently optimized for 16 cores, can scale to 32+ cores
- **Memory**: Using ~24GB of 128GB, significant headroom available
- **Storage**: Modular storage approach allows easy expansion
- **Network**: Gigabit connection sufficient for current load

## Future Architecture Evolution

### Planned Enhancements

1. **Kubernetes Migration**: Transition from Docker Compose to Kubernetes
2. **Multi-Node Cluster**: Distribute services across multiple nodes
3. **Advanced Monitoring**: APM integration, distributed tracing
4. **Enhanced Security**: Zero-trust networking, advanced RBAC
5. **Edge Computing**: CDN integration for global content delivery

### Technology Roadmap

- **Short Term** (3-6 months): Enhanced monitoring, automated updates
- **Medium Term** (6-12 months): Multi-node deployment, advanced security
- **Long Term** (1-2 years): Cloud-native architecture, edge integration

This architecture provides a solid foundation for a production-grade homeserver while maintaining flexibility for future enhancements and scaling requirements.