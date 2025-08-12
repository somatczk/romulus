# Production Deployment Guide

This guide covers deploying Romulus Elixir in production environments with high availability, monitoring, and safety considerations.

## Pre-Deployment Checklist

### System Requirements

- [ ] Elixir 1.17+ and Erlang/OTP 26+
- [ ] libvirt 8.0+ with KVM support
- [ ] Minimum 32GB RAM for full cluster
- [ ] 500GB+ SSD storage
- [ ] Network connectivity between nodes
- [ ] SSH key infrastructure in place

### Security Checklist

- [ ] libvirt access controls configured
- [ ] SSH keys properly secured
- [ ] Network isolation configured
- [ ] Firewall rules in place
- [ ] SELinux/AppArmor policies reviewed

## Step-by-Step Deployment

### 1. Initial Setup

```bash
# Clone repository
git clone https://github.com/your-org/romulus.git
cd romulus

# Switch to stable release
git checkout v1.0.0

# Setup Elixir environment
cd romulus_elixir
mix deps.get --only prod
MIX_ENV=prod mix compile
```

### 2. Configuration Validation

Create production configuration:

```yaml
# romulus.prod.yaml
cluster:
  name: prod-k8s-cluster
  domain: k8s.prod.local

network:
  name: prod-k8s-network
  mode: bridge  # Use bridge for production
  cidr: 10.20.0.0/16
  dhcp: false   # Static IPs in production
  dns: true

storage:
  pool_name: prod-k8s-pool
  pool_path: /data/libvirt/prod-k8s
  base_image:
    name: ubuntu-22.04-base
    url: https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
    format: qcow2

nodes:
  masters:
    count: 3  # HA configuration
    memory: 8192
    vcpus: 4
    disk_size: 107374182400  # 100GB
    ip_prefix: "10.20.1."
    
  workers:
    count: 5
    memory: 32768
    vcpus: 8
    disk_size: 536870912000  # 500GB
    ip_prefix: "10.20.2."

ssh:
  public_key_path: /etc/romulus/keys/prod_key.pub
  user: ubuntu

kubernetes:
  version: "1.28.5"
  pod_subnet: "10.244.0.0/16"
  service_subnet: "10.96.0.0/12"
  
bootstrap:
  cni: calico  # Production CNI
  ingress: nginx
  storage: rook-ceph
  monitoring: prometheus
  logging: loki
```

Validate configuration:

```bash
MIX_ENV=prod mix romulus.validate --config romulus.prod.yaml
```

### 3. Pre-Flight Checks

Run comprehensive pre-flight checks:

```bash
# Check system resources
make metrics

# Verify libvirt
virsh version
virsh capabilities

# Test connectivity
MIX_ENV=prod mix romulus.preflight --config romulus.prod.yaml
```

### 4. Staged Deployment

#### Stage 1: Infrastructure Foundation

```bash
# Plan infrastructure
MIX_ENV=prod mix romulus.plan --config romulus.prod.yaml

# Review plan carefully
# Apply with staged approach
MIX_ENV=prod mix romulus.apply --config romulus.prod.yaml --stage foundation
```

#### Stage 2: Master Nodes

```bash
# Deploy master nodes
MIX_ENV=prod mix romulus.apply --config romulus.prod.yaml --stage masters

# Verify masters are running
virsh list --all | grep master

# Test SSH connectivity
for i in {1..3}; do
  ssh ubuntu@10.20.1.$i hostname
done
```

#### Stage 3: Worker Nodes

```bash
# Deploy workers in batches
MIX_ENV=prod mix romulus.apply --config romulus.prod.yaml --stage workers --batch-size 2

# Monitor deployment
watch -n 5 'virsh list --all'
```

### 5. Kubernetes Bootstrap

#### Initialize Cluster

```bash
# Bootstrap Kubernetes with HA configuration
MIX_ENV=prod mix romulus.k8s.bootstrap --config romulus.prod.yaml --ha

# Wait for cluster to stabilize
kubectl wait --for=condition=Ready nodes --all --timeout=600s
```

#### Deploy Core Components

```bash
# Apply CNI
kubectl apply -f kubernetes/bootstrap/calico.yaml

# Deploy metrics server
kubectl apply -f kubernetes/bootstrap/metrics-server.yaml

# Setup ingress controller
kubectl apply -f kubernetes/core/ingress/nginx/
```

### 6. Verification

Run comprehensive tests:

```bash
# Infrastructure tests
MIX_ENV=prod mix test.integration

# Kubernetes tests
kubectl run test-pod --image=nginx --restart=Never
kubectl expose pod test-pod --port=80 --type=ClusterIP
kubectl run test-client --image=busybox --restart=Never -- wget -O- test-pod

# Cleanup test resources
kubectl delete pod test-pod test-client
kubectl delete service test-pod
```

## Monitoring Setup

### 1. Enable Telemetry

```elixir
# config/prod.exs
config :romulus_elixir,
  telemetry_enabled: true,
  telemetry_endpoint: "https://metrics.example.com",
  telemetry_interval: 30_000
```

### 2. Deploy Monitoring Stack

```bash
# Prometheus
kubectl apply -f kubernetes/platform/monitoring/prometheus/

# Grafana
kubectl apply -f kubernetes/platform/monitoring/grafana/

# Configure dashboards
kubectl apply -f kubernetes/platform/monitoring/dashboards/
```

### 3. Setup Alerts

```yaml
# alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: romulus-alerts
spec:
  groups:
  - name: infrastructure
    rules:
    - alert: NodeDown
      expr: up{job="node-exporter"} == 0
      for: 5m
      annotations:
        summary: "Node {{ $labels.instance }} is down"
        
    - alert: HighMemoryUsage
      expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1
      for: 10m
      annotations:
        summary: "High memory usage on {{ $labels.instance }}"
```

## Backup and Recovery

### 1. Automated Backups

```bash
# Setup backup schedule
cat > /etc/cron.d/romulus-backup << EOF
0 2 * * * root /usr/local/bin/romulus-backup.sh
EOF

# Backup script
cat > /usr/local/bin/romulus-backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/backup/romulus/$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Export state
cd /opt/romulus/romulus_elixir
MIX_ENV=prod mix romulus.export-state > $BACKUP_DIR/state.json

# Backup etcd
ETCDCTL_API=3 etcdctl snapshot save $BACKUP_DIR/etcd.db

# Backup persistent volumes
kubectl get pv -o json > $BACKUP_DIR/persistent-volumes.json

# Compress
tar -czf $BACKUP_DIR.tar.gz $BACKUP_DIR
rm -rf $BACKUP_DIR

# Rotate old backups (keep 30 days)
find /backup/romulus -name "*.tar.gz" -mtime +30 -delete
EOF

chmod +x /usr/local/bin/romulus-backup.sh
```

### 2. Disaster Recovery

```bash
# Restore from backup
BACKUP_DATE=20240115
tar -xzf /backup/romulus/${BACKUP_DATE}.tar.gz -C /tmp

# Restore infrastructure
cd /opt/romulus/romulus_elixir
MIX_ENV=prod mix romulus.restore --state /tmp/backup/romulus/${BACKUP_DATE}/state.json

# Restore etcd
ETCDCTL_API=3 etcdctl snapshot restore /tmp/backup/romulus/${BACKUP_DATE}/etcd.db

# Restore Kubernetes state
kubectl apply -f /tmp/backup/romulus/${BACKUP_DATE}/persistent-volumes.json
```

## Rolling Updates

### 1. Update Configuration

```bash
# Edit configuration
vim romulus.prod.yaml

# Validate changes
MIX_ENV=prod mix romulus.plan --config romulus.prod.yaml

# Review changes carefully
```

### 2. Apply Updates

```bash
# Apply with rolling strategy
MIX_ENV=prod mix romulus.apply \
  --config romulus.prod.yaml \
  --strategy rolling \
  --max-unavailable 1

# Monitor progress
watch -n 5 'kubectl get nodes'
```

## Troubleshooting

### Common Issues

#### 1. VM Creation Failures

```bash
# Check libvirt logs
journalctl -u libvirtd -f

# Verify storage pool
virsh pool-info prod-k8s-pool

# Check available resources
free -h
df -h
```

#### 2. Network Connectivity Issues

```bash
# Check network configuration
virsh net-info prod-k8s-network

# Verify bridge
ip addr show br0

# Test connectivity
ping -c 3 10.20.1.1
```

#### 3. Kubernetes Bootstrap Failures

```bash
# Check kubelet logs
journalctl -u kubelet -f

# Verify etcd cluster
ETCDCTL_API=3 etcdctl member list

# Check certificates
kubeadm certs check-expiration
```

### Debug Mode

Enable detailed logging:

```bash
# Set log level
export ROMULUS_LOG_LEVEL=debug

# Enable libvirt debug
export LIBVIRT_DEBUG=1

# Run with debug output
MIX_ENV=prod mix romulus.plan --debug
```

## Performance Tuning

### 1. libvirt Optimization

```xml
<!-- /etc/libvirt/qemu.conf -->
<qemu>
  <migration>
    <compression>
      <level>9</level>
      <threads>4</threads>
    </compression>
  </migration>
  <cache>
    <mode>none</mode>
  </cache>
</qemu>
```

### 2. VM Performance

```yaml
# romulus.prod.yaml optimization
nodes:
  masters:
    cpu_mode: host-passthrough
    numa_topology: true
    huge_pages: true
```

### 3. Network Performance

```bash
# Enable SR-IOV if available
modprobe vfio-pci
echo "8086:10fb" > /sys/bus/pci/drivers/vfio-pci/new_id

# Tune network parameters
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
```

## Security Hardening

### 1. Access Control

```bash
# Restrict libvirt access
cat > /etc/polkit-1/rules.d/50-libvirt.rules << EOF
polkit.addRule(function(action, subject) {
  if (action.id == "org.libvirt.unix.manage" &&
      subject.isInGroup("libvirt-admin")) {
    return polkit.Result.YES;
  }
});
EOF
```

### 2. Encryption

```yaml
# Enable encryption for storage
storage:
  encryption:
    enabled: true
    cipher: aes-256-cbc
    key_file: /etc/romulus/keys/storage.key
```

### 3. Audit Logging

```bash
# Enable audit logging
cat > /etc/rsyslog.d/romulus.conf << EOF
:programname, isequal, "romulus" /var/log/romulus/audit.log
& stop
EOF

systemctl restart rsyslog
```

## Maintenance Windows

### Planned Maintenance

```bash
# 1. Notify users
kubectl create configmap maintenance-notice \
  --from-literal=message="Maintenance window: 2AM-4AM UTC"

# 2. Cordon nodes
kubectl cordon k8s-worker-1

# 3. Drain workloads
kubectl drain k8s-worker-1 --ignore-daemonsets --delete-emptydir-data

# 4. Perform maintenance
MIX_ENV=prod mix romulus.maintain --node k8s-worker-1

# 5. Uncordon node
kubectl uncordon k8s-worker-1
```

## Health Checks

### Automated Health Monitoring

```bash
# Create health check script
cat > /usr/local/bin/romulus-health.sh << 'EOF'
#!/bin/bash
set -e

# Check infrastructure
cd /opt/romulus/romulus_elixir
MIX_ENV=prod mix romulus.health --quiet || exit 1

# Check Kubernetes
kubectl get nodes --no-headers | grep -v Ready && exit 1

# Check critical pods
kubectl get pods -n kube-system --no-headers | grep -v Running && exit 1

echo "Health check passed"
exit 0
EOF

chmod +x /usr/local/bin/romulus-health.sh

# Add to monitoring
cat > /etc/systemd/system/romulus-health.service << EOF
[Unit]
Description=Romulus Health Check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/romulus-health.sh
EOF

cat > /etc/systemd/system/romulus-health.timer << EOF
[Unit]
Description=Run Romulus Health Check every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl enable --now romulus-health.timer
```

## Support and Escalation

### Support Tiers

1. **L1 - Monitoring Alerts**
   - Automated alerts via Prometheus
   - Slack/PagerDuty integration
   - Response time: 15 minutes

2. **L2 - Operations Team**
   - Infrastructure issues
   - Kubernetes problems
   - Response time: 1 hour

3. **L3 - Engineering**
   - Code changes required
   - Architecture decisions
   - Response time: 4 hours

### Escalation Procedures

```bash
# Generate support bundle
cat > /usr/local/bin/romulus-support-bundle.sh << 'EOF'
#!/bin/bash
BUNDLE_DIR="/tmp/romulus-support-$(date +%Y%m%d-%H%M%S)"
mkdir -p $BUNDLE_DIR

# Collect logs
journalctl -u libvirtd --since "1 hour ago" > $BUNDLE_DIR/libvirt.log
kubectl logs -n kube-system --tail=1000 --all-containers > $BUNDLE_DIR/k8s-system.log

# Collect state
cd /opt/romulus/romulus_elixir
MIX_ENV=prod mix romulus.export-state > $BUNDLE_DIR/state.json

# System info
df -h > $BUNDLE_DIR/disk.txt
free -m > $BUNDLE_DIR/memory.txt
ps aux > $BUNDLE_DIR/processes.txt

# Create bundle
tar -czf $BUNDLE_DIR.tar.gz $BUNDLE_DIR
echo "Support bundle created: $BUNDLE_DIR.tar.gz"
EOF

chmod +x /usr/local/bin/romulus-support-bundle.sh
```

## Compliance and Auditing

### Compliance Checks

```bash
# Run compliance scan
MIX_ENV=prod mix romulus.compliance --standard cis-k8s

# Generate compliance report
MIX_ENV=prod mix romulus.compliance.report --format pdf --output /reports/
```

### Audit Trail

All operations are logged with:
- Timestamp
- User/service account
- Action performed
- Resources affected
- Result status

Access audit logs:
```bash
tail -f /var/log/romulus/audit.log | jq '.'
```

## Capacity Planning

### Monitoring Growth

```bash
# Generate capacity report
MIX_ENV=prod mix romulus.capacity --forecast 90d

# Example output:
# Current Usage:
#   CPU: 45% (180/400 cores)
#   Memory: 62% (396GB/640GB)
#   Storage: 38% (3.8TB/10TB)
#
# 90-day Forecast:
#   CPU: 58% (growth: 13%)
#   Memory: 78% (growth: 16%)
#   Storage: 52% (growth: 14%)
#
# Recommended Actions:
#   - Add 2 worker nodes within 60 days
#   - Expand storage pool within 45 days
```

## Conclusion

This production deployment guide provides a comprehensive approach to deploying and maintaining Romulus infrastructure. Always:

1. Test changes in staging first
2. Follow the principle of least privilege
3. Maintain comprehensive backups
4. Monitor continuously
5. Document all changes

For additional support, consult the team runbooks or escalate to the infrastructure team.