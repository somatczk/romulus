# Romulus Elixir

Native Elixir infrastructure automation for libvirt/KVM and Kubernetes, providing idempotent, testable, and performant infrastructure management through pure YAML configuration.

## Features

- **Idempotent Operations**: All operations are idempotent - run them multiple times safely
- **Type-Safe Configuration**: Validated configuration with compile-time checks
- **Cloud-Init Support**: Full cloud-init template rendering with EEx
- **Kubernetes Bootstrap**: Automated cluster initialization and node joining
- **Comprehensive Testing**: Unit, integration, and property-based tests
- **Telemetry & Observability**: Built-in metrics and structured logging
- **Parallel Execution**: Concurrent operations where safe
- **Zero State Files**: No state files - queries current state from libvirt

## Quick Start

### Prerequisites

- Elixir 1.17+ and OTP 26+
- libvirt/KVM installed and configured
- `virsh` command available
- `genisoimage` for cloud-init ISO creation
- SSH key for VM access

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/romulus.git
cd romulus/romulus_elixir

# Install dependencies
mix deps.get
mix compile
```

### Configuration

Create or edit `romulus.yaml`:

```yaml
cluster:
  name: k8s-cluster
  domain: k8s.local

network:
  name: k8s-network
  mode: nat
  cidr: 10.10.10.0/24
  dhcp: true
  dns: true

storage:
  pool_name: k8s-cluster-pool
  pool_path: /var/lib/libvirt/images/k8s-cluster
  base_image:
    name: debian-12-base
    url: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2
    format: qcow2

nodes:
  masters:
    count: 2
    memory: 1024  # MB
    vcpus: 1
    disk_size: 53687091200  # 50GB
    ip_prefix: "10.10.10.1"
    
  workers:
    count: 3
    memory: 18432  # MB
    vcpus: 6
    disk_size: 107374182400  # 100GB
    ip_prefix: "10.10.10.2"

ssh:
  public_key_path: /home/user/.ssh/id_rsa.pub
  user: debian

kubernetes:
  version: "1.28"
  pod_subnet: "10.244.0.0/16"
  service_subnet: "10.96.0.0/12"
```

## Usage

### Plan Infrastructure Changes

See what changes would be made without applying them:

```bash
mix romulus.plan
```

Output:
```
🔍 Generating infrastructure plan...

📋 Plan Summary:
============================================================

🆕 To create:
  💾 pool: k8s-cluster-pool
  🌐 network: k8s-network
  📦 volume: debian-12-base
  📦 volume: k8s-master-1-disk
  📦 volume: k8s-master-2-disk
  📦 volume: k8s-worker-1-disk
  📦 volume: k8s-worker-2-disk
  📦 volume: k8s-worker-3-disk
  🖥️ domain: k8s-master-1
  🖥️ domain: k8s-master-2
  🖥️ domain: k8s-worker-1
  🖥️ domain: k8s-worker-2
  🖥️ domain: k8s-worker-3

============================================================
Total: 13 change(s)
```

### Apply Infrastructure

Create or update infrastructure:

```bash
mix romulus.apply

# Auto-approve without confirmation
ROMULUS_AUTO_APPROVE=true mix romulus.apply
```

### Destroy Infrastructure

Remove all infrastructure:

```bash
mix romulus.destroy

# Force destroy without confirmation
ROMULUS_FORCE=true mix romulus.destroy
```

### Validate Cloud-Init Templates

Render and validate cloud-init templates without creating VMs:

```bash
mix romulus.render-cloudinit
```

### Bootstrap Kubernetes

After VMs are created, bootstrap the Kubernetes cluster:

```bash
mix romulus.k8s.bootstrap
```

## Architecture

```
romulus_elixir/
├── lib/
│   ├── romulus_elixir.ex           # Main entry point
│   ├── romulus_elixir/
│   │   ├── application.ex          # OTP application
│   │   ├── cli.ex                  # CLI commands
│   │   ├── config.ex               # Configuration management
│   │   ├── state.ex                # State representation
│   │   ├── planner.ex              # Plan generation
│   │   ├── executor.ex             # Plan execution
│   │   ├── libvirt.ex              # Libvirt interface
│   │   ├── libvirt/
│   │   │   ├── adapter.ex          # Adapter behaviour
│   │   │   └── virsh.ex            # Virsh implementation
│   │   ├── cloudinit/
│   │   │   ├── renderer.ex         # Template rendering
│   │   │   └── generator.ex        # ISO generation
│   │   └── k8s/
│   │       └── bootstrap.ex        # Kubernetes bootstrap
├── priv/
│   └── cloud-init/                 # Cloud-init templates
├── test/                           # Tests
├── mix.exs                         # Project configuration
└── romulus.yaml                    # Infrastructure config
```

## Development

### Running Tests

```bash
# All tests
mix test

# Unit tests only
mix test.unit

# Integration tests
mix test.integration

# With coverage
mix coveralls.html
```

### Code Quality

```bash
# Format code
mix format

# Run linter
mix credo --strict

# Type checking
mix dialyzer

# Security analysis
mix sobelow
```

### Building a Release

```bash
MIX_ENV=prod mix release

# Run the release
_build/prod/rel/romulus/bin/romulus start
```

## Configuration Management

Romulus uses pure YAML configuration files for infrastructure definition:

- **Declarative**: Define your desired infrastructure state in YAML
- **Stateless**: No state files to manage - queries libvirt directly  
- **Type-safe**: Configuration validated at compile time
- **Idempotent**: Safe to run multiple times
- **Version controlled**: Configuration files work with standard VCS workflows

## Key Benefits

- **No State Management**: Unlike traditional IaC tools, Romulus queries the current state directly from libvirt
- **Native Elixir**: Leverage Elixir's concurrency, fault tolerance, and OTP supervision trees
- **Comprehensive Testing**: Unit, integration, and property-based tests ensure reliability
- **Built-in Observability**: Structured logging and telemetry out of the box
- **Interactive Development**: Use IEx REPL for debugging and experimentation

## Troubleshooting

### Enable Debug Logging

```bash
export ROMULUS_LOG_LEVEL=debug
mix romulus.plan
```

### Common Issues

1. **Permission Denied**
   ```bash
   sudo usermod -aG libvirt $USER
   newgrp libvirt
   ```

2. **Network Already Exists**
   ```bash
   virsh net-destroy k8s-network
   virsh net-undefine k8s-network
   ```

3. **Pool Path Not Found**
   ```bash
   sudo mkdir -p /var/lib/libvirt/images/k8s-cluster
   sudo chown libvirt:libvirt /var/lib/libvirt/images/k8s-cluster
   ```

## Configuration Reference

### Cluster Configuration

- `cluster.name`: Cluster identifier
- `cluster.domain`: DNS domain for the cluster

### Network Configuration

- `network.name`: libvirt network name
- `network.mode`: Network mode (nat, bridge, etc.)
- `network.cidr`: Network CIDR block
- `network.dhcp`: Enable DHCP
- `network.dns`: Enable DNS

### Storage Configuration

- `storage.pool_name`: libvirt storage pool name
- `storage.pool_path`: File system path for pool
- `storage.base_image.url`: Base OS image URL
- `storage.base_image.format`: Image format (qcow2, raw)

### Node Configuration

- `nodes.{masters,workers}.count`: Number of nodes
- `nodes.{masters,workers}.memory`: Memory in MB
- `nodes.{masters,workers}.vcpus`: Number of vCPUs
- `nodes.{masters,workers}.disk_size`: Disk size in bytes
- `nodes.{masters,workers}.ip_prefix`: IP address prefix

### SSH Configuration

- `ssh.public_key_path`: Path to SSH public key
- `ssh.user`: Default SSH user

### Kubernetes Configuration

- `kubernetes.version`: Kubernetes version
- `kubernetes.pod_subnet`: Pod network CIDR
- `kubernetes.service_subnet`: Service network CIDR

### Bootstrap Configuration

- `bootstrap.cni`: CNI plugin (flannel, calico)
- `bootstrap.ingress`: Ingress controller (nginx, traefik)
- `bootstrap.storage`: Storage solution (rook-ceph, local)
- `bootstrap.monitoring`: Monitoring stack (prometheus)
- `bootstrap.logging`: Logging solution (loki, elk)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Run `mix quality` to check code quality
5. Submit a pull request

## License

MIT License - See LICENSE file for details

## Support

- Documentation: [docs/](docs/)
- Issues: GitHub Issues
- Migration Guide: [docs/migration.md](docs/migration.md)