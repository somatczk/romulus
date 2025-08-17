# GitHub Actions Self-Hosted Runner Setup

## Overview

This homeserver infrastructure includes a containerized self-hosted GitHub Actions runner that enables automated CI/CD deployments directly on your server. The runner integrates seamlessly with the existing monitoring, security, and storage architecture.

## Features

- 🐳 **Containerized**: Runs in Docker with proper isolation
- 🔒 **Secure**: Network isolation with controlled access
- 📊 **Monitored**: Integrated with Prometheus, Grafana, and alerting
- ⚡ **Cached**: Redis cache for faster build times
- 🔄 **Self-Healing**: Automatic restarts and health checks
- 💾 **Persistent**: Work directory survives container restarts

## Quick Start

### 1. Generate GitHub Runner Token

1. Go to your repository on GitHub
2. Navigate to **Settings** > **Actions** > **Runners**
3. Click **New self-hosted runner**
4. Copy the registration token (starts with `AAAA...`)

### 2. Configure Environment Variables

Add these variables to your `.env` file:

```bash
# GitHub Runner Configuration
GITHUB_REPOSITORY=yourusername/yourrepo
GITHUB_RUNNER_TOKEN=AAAAB3NzaC1...  # From step 1
RUNNER_NAME=homeserver-runner
PROJECT_PATH=/path/to/your/homeserver/repo  # Absolute path

# Optional: Customize runner resources
RUNNER_MEMORY_LIMIT=2g
RUNNER_CPU_LIMIT=2.0
```

### 3. Deploy the Runner

```bash
# Deploy with runner included
./scripts/deploy.sh

# Or deploy just the runner
docker-compose -f docker-compose.yml -f docker-compose.runner.yml up -d github-runner
```

### 4. Verify Installation

```bash
# Check runner status
docker-compose -f docker-compose.runner.yml ps

# View runner logs
docker-compose -f docker-compose.runner.yml logs github-runner

# Run health check
./scripts/healthcheck.sh --verbose
```

## Architecture

### Container Structure

```
github-runner/          # Main runner container
├── /tmp/runner/work   # Job workspace (persisted)
├── /tmp/runner/externals  # Runner tools
├── /workspace         # Read-only access to repo
└── /var/run/docker.sock  # Docker socket access

runner-cache/          # Redis cache for builds
└── /data             # Cache storage (persisted)

runner-tools/         # Pre-installed build tools
└── /tools           # Shared tools directory
```

### Network Configuration

- **runner-network**: Isolated network (172.20.0.0/16)
- **frontend**: For GitHub API access
- **Access**: No direct container-to-container communication with main services

### Storage Layout

```
${SSD_PATH}/runner/
├── work/              # Job workspaces and artifacts
├── cache/             # Redis cache data
├── tools/             # Shared build tools
└── externals/         # Runner binaries and dependencies
```

## Configuration Options

### Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `GITHUB_REPOSITORY` | Repository URL (owner/repo) | - | Yes |
| `GITHUB_RUNNER_TOKEN` | Registration token from GitHub | - | Yes |
| `RUNNER_NAME` | Name for the runner | homeserver-runner | No |
| `RUNNER_GROUP` | Runner group assignment | default | No |
| `RUNNER_EPHEMERAL` | Remove runner after each job | false | No |
| `PROJECT_PATH` | Absolute path to repository | - | Yes |
| `RUNNER_MEMORY_LIMIT` | Memory limit for runner | 2g | No |
| `RUNNER_CPU_LIMIT` | CPU limit for runner | 2.0 | No |

### Resource Limits

**Default Allocation:**
- Memory: 2GB (with 1GB reservation)
- CPU: 2 cores
- Storage: Unlimited on SSD partition

**Recommended for Heavy Builds:**
```bash
RUNNER_MEMORY_LIMIT=4g
RUNNER_MEMORY_RESERVATION=2g
RUNNER_CPU_LIMIT=4.0
```

## Monitoring and Alerts

### Prometheus Metrics

The runner exposes standard container metrics via cAdvisor:
- CPU usage: `container_cpu_usage_seconds_total{name="github-runner"}`
- Memory usage: `container_memory_usage_bytes{name="github-runner"}`
- Network I/O: `container_network_*{name="github-runner"}`

### Grafana Dashboard

Runner metrics are included in the main homeserver dashboard:
- Runner status and uptime
- Resource usage graphs
- Job execution history
- Cache hit rates

### Alert Rules

Configured alerts for runner issues:
- `GitHubRunnerDown`: Runner container stopped
- `GitHubRunnerHighCPU`: CPU usage > 80%
- `GitHubRunnerHighMemory`: Memory usage > 90%
- `GitHubRunnerStorageFull`: Disk space < 20%
- `GitHubRunnerLongJob`: Jobs running > 2 hours

## Operations

### Starting/Stopping

```bash
# Start runner services
docker-compose -f docker-compose.runner.yml up -d

# Stop runner services
docker-compose -f docker-compose.runner.yml down

# Restart runner
docker-compose -f docker-compose.runner.yml restart github-runner
```

### Maintenance

```bash
# View runner logs
docker-compose -f docker-compose.runner.yml logs -f github-runner

# Clean up old workspaces
docker exec github-runner find /tmp/runner/work -type d -mtime +7 -exec rm -rf {} +

# Update runner image
docker-compose -f docker-compose.runner.yml pull github-runner
docker-compose -f docker-compose.runner.yml up -d github-runner

# Check runner registration
docker exec github-runner /opt/runner/bin/Runner.Listener run --help
```

### Backup and Recovery

The runner's work directory is automatically backed up with the regular backup script:

```bash
# Manual backup of runner data
./scripts/backup.sh --type config

# Restore runner data (if needed)
# Runner will auto-register on next startup
```

## Troubleshooting

### Runner Not Registering

1. **Check token validity:**
   ```bash
   # Token expires after 1 hour
   # Generate new token from GitHub Settings > Actions > Runners
   ```

2. **Verify network connectivity:**
   ```bash
   docker exec github-runner curl -s https://api.github.com/zen
   ```

3. **Check registration logs:**
   ```bash
   docker-compose -f docker-compose.runner.yml logs github-runner | grep -i register
   ```

### High Resource Usage

1. **Check running jobs:**
   ```bash
   docker exec github-runner ps aux
   ```

2. **Monitor resource usage:**
   ```bash
   docker stats github-runner --no-stream
   ```

3. **Adjust resource limits:**
   ```bash
   # In .env file
   RUNNER_MEMORY_LIMIT=4g
   RUNNER_CPU_LIMIT=4.0
   ```

### Permission Issues

1. **Fix Docker socket permissions:**
   ```bash
   sudo usermod -aG docker runner
   docker-compose -f docker-compose.runner.yml restart github-runner
   ```

2. **Check workspace permissions:**
   ```bash
   sudo chown -R 1000:1000 ${SSD_PATH}/runner/
   ```

### Storage Issues

1. **Clean up workspace:**
   ```bash
   docker exec github-runner find /tmp/runner/work -type f -mtime +3 -delete
   ```

2. **Clear cache:**
   ```bash
   docker-compose -f docker-compose.runner.yml restart runner-cache
   ```

3. **Monitor disk usage:**
   ```bash
   du -sh ${SSD_PATH}/runner/
   ```

## Security Considerations

### Access Control

- Runner has Docker socket access (required for containerized jobs)
- Read-only access to repository workspace
- Network isolation from internal services
- Non-root execution where possible

### Best Practices

1. **Rotate tokens regularly** (GitHub tokens expire after 1 hour)
2. **Monitor runner logs** for suspicious activity
3. **Use ephemeral runners** for sensitive repositories
4. **Limit repository access** to specific branches/paths
5. **Review workflow permissions** regularly

### Network Security

```yaml
# Runner network is isolated
networks:
  runner-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
```

## Performance Optimization

### Build Caching

The runner includes a Redis cache service for build acceleration:

```yaml
# Access cache from workflows
- name: Setup Cache
  run: |
    export REDIS_URL=redis://runner-cache:6379
    # Use cache in your build steps
```

### Resource Tuning

For different workload types:

**Light builds (documentation, simple apps):**
```bash
RUNNER_MEMORY_LIMIT=1g
RUNNER_CPU_LIMIT=1.0
```

**Heavy builds (large applications, Docker builds):**
```bash
RUNNER_MEMORY_LIMIT=8g
RUNNER_CPU_LIMIT=6.0
```

**Parallel job processing:**
- Multiple runners can be deployed with different names
- Each runner can handle one job at a time
- Scale horizontally for concurrent jobs

## Integration Examples

### Basic Deployment Workflow

```yaml
name: Deploy to Homeserver
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: self-hosted
    steps:
    - uses: actions/checkout@v4
    - name: Deploy Infrastructure
      run: ./scripts/deploy.sh
```

### Docker Build Workflow

```yaml
name: Build and Deploy
jobs:
  build:
    runs-on: self-hosted
    steps:
    - uses: actions/checkout@v4
    - name: Build Docker Image
      run: |
        docker build -t myapp:latest .
        docker-compose up -d myapp
```

### Advanced Features

```yaml
name: Advanced Deployment
jobs:
  deploy:
    runs-on: self-hosted
    steps:
    - uses: actions/checkout@v4
    
    # Use runner cache
    - name: Restore Cache
      run: |
        redis-cli -h runner-cache ping
        # Implement your caching logic
    
    # Self-monitoring
    - name: Check Runner Health
      run: ./scripts/healthcheck.sh --json
    
    # Deployment with validation
    - name: Deploy with Validation
      run: |
        ./scripts/deploy.sh
        ./scripts/healthcheck.sh --verbose
```

## Support

For issues and questions:

1. Check runner logs: `docker-compose -f docker-compose.runner.yml logs github-runner`
2. Run health checks: `./scripts/healthcheck.sh --verbose`
3. Monitor in Grafana: `https://monitoring.${DOMAIN}`
4. Review GitHub Actions logs in the repository

## Changelog

- **v1.0**: Initial runner implementation with basic monitoring
- **v1.1**: Added Redis caching and build tools
- **v1.2**: Enhanced monitoring and alerting
- **v1.3**: Self-healing capabilities and improved security

---

**Next Steps:** After setting up the runner, configure your GitHub repository's Actions to use the `self-hosted` label and deploy your infrastructure automatically on every push to the main branch.