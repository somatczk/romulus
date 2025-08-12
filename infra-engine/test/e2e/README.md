# End-to-End (E2E) Tests

This directory contains comprehensive end-to-end tests for Romulus infrastructure management. These tests validate the complete infrastructure lifecycle including provisioning, configuration, and teardown.

## Prerequisites

Before running E2E tests, ensure you have:

1. **libvirt/KVM environment** configured and running
2. **virsh command** available and working
3. **SSH client** installed
4. **Sufficient disk space** (at least 20GB free in `/tmp`)
5. **Network connectivity** for downloading base images

## Test Categories

### Smoke Tests (`@tag :smoke`)
- Complete infrastructure lifecycle validation
- Applies full cluster configuration
- Verifies VM connectivity and services
- Performs complete teardown

### Rollback Tests (`@tag :rollback`) 
- Failure recovery scenarios
- Configuration corruption handling
- Partial application testing
- Cleanup after failures

### Resilience Tests (`@tag :resilience`)
- Resource conflict handling
- Concurrent operation testing
- Recovery from system errors
- Resource consistency validation

### Kubernetes Bootstrap Tests (`@tag :k8s_bootstrap`)
- Complete infrastructure provisioning and K8s cluster bootstrap
- Node readiness verification with 10-minute timeout
- Dummy workload deployment and health checks
- Cluster functionality validation through kubectl commands

## Running E2E Tests

### All E2E Tests
```bash
# Run all E2E tests (requires libvirt environment)
mix test.e2e

# Or manually with more control
mix test test/e2e --include e2e
```

### Specific Test Categories
```bash
# Run only smoke tests
mix test test/e2e --include e2e --only smoke

# Run only rollback tests  
mix test test/e2e --include e2e --only rollback

# Run only resilience tests
mix test test/e2e --include e2e --only resilience

# Run only k8s bootstrap tests
mix test test/e2e --include e2e --only k8s_bootstrap
```

### With Environment Variables
```bash
# Skip SSH connectivity tests (useful if VMs don't have SSH configured)
ROMULUS_E2E_SKIP_SSH=true mix test.e2e

# Custom test timeout (default 10 minutes)
ROMULUS_E2E_TIMEOUT=1200000 mix test.e2e  # 20 minutes

# Disable cleanup after test failure (for debugging)
ROMULUS_E2E_CLEANUP=false mix test.e2e

# Verbose output for debugging
mix test test/e2e --include e2e --trace
```

## Test Infrastructure

### Test Resources
E2E tests create isolated test resources:
- **Cluster name**: `romulus-e2e-smoke`
- **Network**: `romulus-e2e-smoke-network` (192.168.250.0/24)
- **Storage pool**: `romulus-e2e-smoke-pool` (/tmp/romulus-e2e-test)
- **SSH keys**: `/tmp/romulus_e2e_test` and `/tmp/romulus_e2e_test.pub`

### Test VMs
- **1 Master node**: 1.5GB RAM, 2 vCPUs, 10GB disk
- **1 Worker node**: 1.5GB RAM, 2 vCPUs, 10GB disk
- **Base image**: Debian 12 cloud image (downloaded automatically)

### Cleanup
Tests automatically clean up resources after completion. If tests fail, you can manually clean up:

```bash
# Remove test VMs
virsh list --all | grep romulus-e2e-smoke | awk '{print $2}' | xargs -r virsh destroy
virsh list --all | grep romulus-e2e-smoke | awk '{print $2}' | xargs -r virsh undefine --remove-all-storage

# Remove test network
virsh net-destroy romulus-e2e-smoke-network 2>/dev/null || true
virsh net-undefine romulus-e2e-smoke-network 2>/dev/null || true

# Remove test pool
virsh pool-destroy romulus-e2e-smoke-pool 2>/dev/null || true  
virsh pool-undefine romulus-e2e-smoke-pool 2>/dev/null || true

# Remove test files
rm -rf /tmp/romulus-e2e-test
rm -f /tmp/romulus_e2e_test /tmp/romulus_e2e_test.pub
```

## Test Scenarios

### 1. Complete Infrastructure Lifecycle
1. Verifies empty initial state
2. Applies complete cluster configuration via `mix romulus.apply`
3. Validates infrastructure creation (VMs, networks, storage)
4. Tests SSH connectivity to all VMs (optional)
5. Checks kubelet service availability
6. Destroys infrastructure via `mix romulus.destroy`
7. Validates complete cleanup

### 2. Rollback and Recovery
1. Partially applies infrastructure (network + storage only)
2. Simulates configuration failure with invalid config
3. Verifies graceful failure handling
4. Ensures no infrastructure corruption
5. Performs rollback cleanup
6. Validates complete cleanup

### 3. Resource Conflicts
1. Pre-creates conflicting libvirt resources
2. Attempts to apply Romulus configuration
3. Verifies conflict resolution
4. Ensures infrastructure consistency
5. Cleans up all resources

### 4. Kubernetes Bootstrap and Health Verification
1. Applies complete infrastructure configuration
2. Calls `mix romulus.k8s.bootstrap` to bootstrap K8s cluster
3. Waits for all nodes to be ready (10-minute timeout)
4. Runs dummy workload (nginx deployment) to verify cluster functionality
5. Verifies pod deployment and readiness
6. Cleans up test workload and infrastructure

## Debugging Failed Tests

### Enable Verbose Logging
```bash
# Enable debug logging for Romulus operations
export ROMULUS_LOG_LEVEL=debug
mix test test/e2e --include e2e --trace
```

### Inspect Test Resources
```bash
# List test VMs
virsh list --all | grep romulus-e2e-smoke

# Check network status
virsh net-list --all | grep romulus-e2e-smoke

# Check storage pool
virsh pool-list --all | grep romulus-e2e-smoke

# View VM console (if running)
virsh console romulus-e2e-smoke-master-1
```

### Test State Inspection
```bash
# Check libvirt state during test
virsh list --all
virsh net-list --all
virsh pool-list --all

# Monitor resource usage
df -h /tmp
free -h
```

## Performance Expectations

- **Complete lifecycle test**: ~8-12 minutes
- **VM boot time**: ~2-3 minutes per VM
- **Image download**: ~1-2 minutes (first run only)
- **SSH connectivity**: ~30 seconds
- **Infrastructure teardown**: ~2-3 minutes

## Troubleshooting

### Common Issues

**libvirt Permission Denied**
```bash
sudo usermod -aG libvirt $USER
newgrp libvirt
```

**Network Already Exists**
```bash
virsh net-destroy romulus-e2e-smoke-network
virsh net-undefine romulus-e2e-smoke-network
```

**Insufficient Disk Space**
```bash
# Clean up old test artifacts
rm -rf /tmp/romulus-*
```

**SSH Connection Timeouts**
```bash
# Skip SSH tests if VMs aren't fully configured
ROMULUS_E2E_SKIP_SSH=true mix test.e2e
```

### Getting Help

- Check test logs for detailed error messages
- Verify libvirt is running: `systemctl status libvirtd`
- Ensure adequate system resources
- Try running tests individually for better debugging

## Contributing

When adding new E2E tests:

1. Use appropriate tags (`@tag :e2e` and specific category)
2. Set reasonable timeouts for long-running operations
3. Always clean up test resources in `on_exit/1`
4. Use descriptive test names and documentation
5. Add any new environment variables to this documentation
