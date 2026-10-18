#!/usr/bin/env bash
# Rebuild the CI VM (k3s node) on romulus. Run as root on the host.
#   scripts/ci-vm/create.sh /path/to/admin_key.pub
# Then follow the bootstrap steps in README.md (CI platform).
set -euo pipefail

PUBKEY=${1:?usage: create.sh <ssh public key file>}
V=/media/SSD-Storage/vms
NAME=romulus-ci
MAC=52:54:00:c1:00:01
IP=192.168.122.10
IMG_URL=https://cloud-images.ubuntu.com/resolute/current
K3S_VERSION=v1.36.5+k3s1

virsh dominfo "$NAME" >/dev/null 2>&1 && { echo "$NAME exists; virsh undefine it first"; exit 1; }
mkdir -p "$V/seed" && cd "$V"

curl -fsSL -o base.img "$IMG_URL/resolute-server-cloudimg-amd64.img"
curl -fsSL "$IMG_URL/SHA256SUMS" | awk '$2 ~ /resolute-server-cloudimg-amd64.img$/ {print $1"  base.img"}' | sha256sum -c -
qemu-img convert -O qcow2 base.img "$NAME.qcow2"
qemu-img resize "$NAME.qcow2" 250G

cat > seed/meta-data <<META
instance-id: $NAME-$(date +%s)
local-hostname: $NAME
META

cat > seed/user-data <<USER
#cloud-config
hostname: $NAME
users:
  - name: somatczk
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys: ["$(cat "$PUBKEY")"]
ssh_pwauth: false
disable_root: true
package_update: true
package_upgrade: true
packages: [qemu-guest-agent, curl, jq, unattended-upgrades]
write_files:
  - path: /etc/rancher/k3s/config.yaml
    content: |
      write-kubeconfig-mode: "0600"
      disable: [traefik, servicelb]
      tls-san: [$IP]
      kubelet-arg:
        - max-pods=200
        - system-reserved=cpu=1,memory=2Gi
        - kube-reserved=cpu=1,memory=2Gi
        - eviction-hard=memory.available<2Gi,nodefs.available<10%,imagefs.available<10%
  - path: /etc/sysctl.d/90-ci.conf
    content: |
      fs.inotify.max_user_instances=8192
      fs.inotify.max_user_watches=1048576
      vm.max_map_count=262144
runcmd:
  - sysctl --system
  - systemctl enable --now qemu-guest-agent
  - curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
  - INSTALL_K3S_VERSION=$K3S_VERSION sh /tmp/k3s-install.sh
USER
cloud-localds seed.iso seed/user-data seed/meta-data

# Fixed address: the host firewall and the kubeconfig tunnel point at it.
virsh net-update default add ip-dhcp-host "<host mac='$MAC' name='$NAME' ip='$IP'/>" --live --config || true

virt-install --name "$NAME" --memory 98304 --vcpus 24 --cpu host-passthrough \
  --disk path="$V/$NAME.qcow2",format=qcow2,bus=virtio,cache=none,discard=unmap \
  --disk path="$V/seed.iso",device=cdrom \
  --network network=default,mac=$MAC,model=virtio \
  --os-variant ubuntu24.04 --boot uefi --graphics none --noautoconsole --autostart --import
echo "$NAME starting at $IP; k3s installs on first boot."
