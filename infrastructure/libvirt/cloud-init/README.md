# Cloud-Init Templates for Kubernetes Nodes

This directory contains cloud-init templates that automatically configure Debian-based VMs for Kubernetes deployment.

## Template Files

### 1. `master-config.yaml` / `cloud-init-master.yml`
**Purpose:** Configures master nodes with full Kubernetes control plane components

**What it does:**
- Creates `debian` user with SSH key access
- Installs Docker and containerd with proper systemd cgroup configuration
- Installs Kubernetes components: `kubelet`, `kubeadm`, `kubectl`
- Configures kernel modules and sysctl settings for Kubernetes
- Disables swap permanently
- Sets up iptables to use legacy version (required for Kubernetes)
- Configures hostname and `/etc/hosts` with cluster node entries

### 2. `worker-config.yaml` / `cloud-init-worker.yml`
**Purpose:** Configures worker nodes for joining the Kubernetes cluster

**What it does:**
- Same as master config, but installs only `kubelet` and `kubeadm` (no `kubectl`)
- Optimized for worker node role in the cluster

### 3. `network-config.yaml` / `network-config.yml`
**Purpose:** Configures static networking for each node

**What it does:**
- Sets up static IP addresses for each node
- Configures DNS servers (cluster gateway + public DNS)
- Disables DHCP to ensure consistent IP assignments

## IP Address Scheme

- **Network:** `10.10.10.0/24`
- **Gateway:** `10.10.10.1`
- **Master nodes:** `10.10.10.11`, `10.10.10.12`
- **Worker nodes:** `10.10.10.21`, `10.10.10.22`, `10.10.10.23`

## Software Installed

### Container Runtime
- **Docker CE** - Latest stable version
- **containerd** - Configured with systemd cgroups

### Kubernetes Components
- **Version:** 1.28 (stable)
- **Master nodes:** kubelet, kubeadm, kubectl
- **Worker nodes:** kubelet, kubeadm

### Essential Tools
- curl, wget, git, vim, htop, net-tools
- apt-transport-https, ca-certificates, gnupg

## Template Variables

The cloud-init templates use these variables (interpolated by Terraform):

- `${hostname}` - Node hostname (e.g., k8s-master-1)
- `${ssh_key}` - SSH public key content for debian user
- `${node_ip}` - Static IP address for the node
- `${ip_address}` - Same as node_ip (used in network config)

## After VM Deployment

1. **Wait for initialization:** VMs will reboot automatically after cloud-init completes (60-90 seconds)

2. **Verify connectivity:**
   ```bash
   ssh debian@10.10.10.11  # First master
   ssh debian@10.10.10.21  # First worker
   ```

3. **Check cloud-init completion:**
   ```bash
   sudo cloud-init status
   ```

4. **Initialize Kubernetes cluster:**
   ```bash
   # On k8s-master-1
   curl -s https://raw.githubusercontent.com/your-repo/main/infrastructure/scripts/bootstrap-k8s-cluster.sh | bash
   ```

## Troubleshooting

### Cloud-init logs
```bash
sudo journalctl -u cloud-init-local.service
sudo journalctl -u cloud-init.service
sudo tail -f /var/log/cloud-init-output.log
```

### Kubernetes readiness
```bash
systemctl status kubelet
systemctl status containerd
```

### Network issues
```bash
ip addr show
cat /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

## Customization

To modify the templates:

1. Edit the `.yml` files in this directory
2. Common changes:
   - **Kubernetes version:** Change the repository URL in `runcmd` section
   - **Additional packages:** Add to the `packages` list
   - **Custom configurations:** Add to the `write_files` section
   - **Post-install scripts:** Add commands to `runcmd` section

## Security Notes

- SSH password authentication is disabled
- Only key-based SSH access is allowed
- Firewall (ufw) is disabled for Kubernetes networking
- All nodes have sudo access for the `debian` user

## Next Steps

After successful deployment:
1. Initialize the Kubernetes cluster on the first master
2. Join additional masters and workers
3. Deploy CNI (Calico is recommended and included in bootstrap script)
4. Deploy ingress controller and other cluster components 