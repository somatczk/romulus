# Romulus Elixir Configuration Guide

This document provides a comprehensive guide for using Romulus Elixir, a pure Elixir infrastructure automation tool for libvirt/KVM and Kubernetes.

## Overview

Romulus Elixir provides native Elixir infrastructure management with additional benefits:

- **Stateless Operation**: No state files to manage - queries libvirt directly
- **Type-Safe Configuration**: Compile-time validation of all configuration
- **Idempotent Operations**: Safe to run multiple times with same results
- **Comprehensive Testing**: Built-in unit, integration, and property-based tests
- **Native Concurrency**: Leverages Elixir's actor model for parallel operations
- **Rich Observability**: Built-in telemetry, structured logging, and debugging tools

## Configuration Structure

### YAML Configuration Format

All infrastructure is defined in YAML configuration files. The default file is `romulus.yaml`:

```yaml
cluster:
  name: k8s-cluster
  domain: k8s.local
  description: "Kubernetes cluster managed by Romulus"

network:
  name: k8s-network
  mode: nat
  cidr: 10.10.10.0/24
  dhcp: true
  dns: true
  autostart: true

storage:
  pool_name: k8s-cluster-pool
  pool_path: /var/lib/libvirt/images/k8s-cluster
  pool_type: dir
  base_image:
    name: debian-12-base
    url: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2
    format: qcow2
    checksum_algorithm: sha256

nodes:
  masters:
    count: 2
    memory: 2048  # Memory in MB
    vcpus: 2
    disk_size: 53687091200  # Disk size in bytes (50GB)
    ip_prefix: "10.10.10.1"
    role: master
    taints:
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
        
  workers:
    count: 3
    memory: 4096  # Memory in MB
    vcpus: 4
    disk_size: 107374182400  # Disk size in bytes (100GB)
    ip_prefix: "10.10.10.2"
    role: worker
    labels:
      node-role.kubernetes.io/worker: ""

ssh:
  public_key_path: /home/user/.ssh/id_rsa.pub
  private_key_path: /home/user/.ssh/id_rsa
  user: debian
  port: 22
  connection_timeout: 30
  retry_attempts: 3

kubernetes:
  version: "1.28"
  pod_subnet: "10.244.0.0/16"
  service_subnet: "10.96.0.0/12"
  api_server_port: 6443
  cluster_dns: "10.96.0.10"
  cluster_domain: "cluster.local"
  container_runtime: containerd
  cgroup_driver: systemd

bootstrap:
  cni: flannel
  ingress: nginx
  storage: rook-ceph
  monitoring: prometheus
  logging: loki
  cert_manager: true
  dashboard: true
  metrics_server: true
```

## Operations Reference

### Core Operations

| Operation | Command | Description |
|-----------|---------|-------------|
| Initialize | `mix deps.get` | Install dependencies (one-time setup) |
| Plan | `mix romulus.plan` | Generate execution plan |
| Apply | `mix romulus.apply` | Create/update infrastructure |
| Destroy | `mix romulus.destroy` | Remove all infrastructure |
| Format | `mix format` | Format Elixir code |
| Validate | `mix compile --warnings-as-errors` | Compile and validate |

### Development Operations

| Operation | Command | Description |
|-----------|---------|-------------|
| Test | `mix test` | Run test suite |
| Interactive | `iex -S mix` | Start interactive Elixir shell |
| Documentation | `mix docs` | Generate documentation |
| Type Check | `mix dialyzer` | Static analysis with Dialyzer |

## State Management

### Stateless Architecture
- **No state files**: Romulus queries libvirt directly for current state
- **No state corruption**: Cannot get into inconsistent state
- **Version control friendly**: Only configuration files need versioning
- **Concurrent safe**: Multiple operations can run safely

### State Discovery
Romulus automatically discovers the current state by querying libvirt:
- Networks via `virsh net-list`
- Storage pools via `virsh pool-list` 
- Volumes via `virsh vol-list`
- Domains via `virsh list`

## Cloud-Init Templates

Cloud-init templates use native EEx templating syntax:

| Template Variable | EEx Syntax | Description |
|------------------|------------|-------------|
| hostname | `<%= hostname %>` | Node hostname |
| ssh_key | `<%= ssh_key %>` | SSH public key |
| ip_address | `<%= ip_address %>` | Static IP address |

**Example cloud-init template:**
```yaml
#cloud-config
hostname: <%= hostname %>
users:
  - name: debian
    ssh_authorized_keys:
      - <%= ssh_key %>
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    
write_files:
  - path: /etc/netplan/50-cloud-init.yaml
    content: |
      network:
        version: 2
        ethernets:
          ens3:
            addresses:
              - <%= ip_address %>/24
            gateway4: 10.10.10.1
            nameservers:
              addresses: [8.8.8.8, 8.8.4.4]
```

## Advanced Configuration

### Resource Dependencies
Romulus automatically handles resource dependencies:
- Storage pools created before volumes
- Networks created before domains
- Base images downloaded before volume creation
- Cloud-init ISOs generated before domain creation

### Parallel Execution
Operations are executed in parallel where safe:
- Volume creation across different pools
- Domain provisioning (after dependencies met)
- Cloud-init template rendering
- SSH connectivity checks

## Debugging and Troubleshooting

### Enable Debug Logging
```bash
export ROMULUS_LOG_LEVEL=debug
mix romulus.plan
```

### Interactive Debugging
```bash
iex -S mix
```

```elixir
iex> {:ok, config} = RomulusElixir.load_config()
iex> {:ok, current_state} = RomulusElixir.State.fetch_current()
iex> {:ok, desired_state} = RomulusElixir.State.from_config(config)
iex> {:ok, plan} = RomulusElixir.Planner.create_plan(current_state, desired_state)
iex> IO.puts(RomulusElixir.Planner.format_plan(plan))
```

### Health Checks
```bash
# Check libvirt connectivity
mix romulus.health

# Validate configuration
mix romulus.plan --dry-run

# Test cloud-init templates
mix romulus.render_cloudinit
```

## Performance Optimization

The Elixir implementation provides several performance improvements:

| Area | Optimization | Benefit |
|------|-------------|---------|
| Parsing | Compile-time validation | Faster execution |
| Concurrency | Native actor model | Better parallelism |
| Memory | Immutable data structures | Lower memory usage |
| Operations | Idempotent by design | Faster re-runs |
| Debugging | Live introspection | Faster troubleshooting |

## Enhanced Features

The Elixir implementation adds several features:

### Built-in Observability
- Structured JSON logging
- Telemetry metrics collection
- Real-time operation monitoring
- Performance profiling

### Advanced Testing
- Property-based testing with StreamData
- Integration tests with real libvirt
- Mocking and stubbing for unit tests
- Test coverage reporting

### Developer Experience  
- Interactive REPL (IEx) for debugging
- Hot code reloading in development
- Comprehensive error messages
- Built-in documentation generation

## Production Deployment

### Release Building
```bash
# Build production release
MIX_ENV=prod mix release

# Run production binary
_build/prod/rel/romulus/bin/romulus start
```

### Configuration Management
- Environment-specific configuration files
- Runtime configuration via environment variables
- Secrets management via external providers
- Configuration validation on startup

### Monitoring and Alerting
- Prometheus metrics export
- Structured log aggregation
- Health check endpoints
- Performance monitoring dashboards