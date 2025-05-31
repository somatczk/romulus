resource "libvirt_volume" "master_disks" {
  count          = 2
  name           = "k8s-master-${count.index + 1}-disk"
  base_volume_id = libvirt_volume.base_image.id
  pool           = libvirt_pool.k8s_pool.name
  size           = 53687091200  # 50GB
}


resource "libvirt_volume" "worker_disks" {
  count          = 3
  name           = "k8s-worker-${count.index + 1}-disk"
  base_volume_id = libvirt_volume.base_image.id
  pool           = libvirt_pool.k8s_pool.name
  size           = 107374182400  # 100GB
}

resource "libvirt_cloudinit_disk" "master_init" {
  count = 2
  name  = "k8s-master-${count.index + 1}-init.iso"
  pool  = libvirt_pool.k8s_pool.name

  user_data = templatefile("${path.module}/cloud-init-master.yml", {
    hostname = "k8s-master-${count.index + 1}"
    ssh_key  = file(var.ssh_public_key_path)
    node_ip  = "10.10.10.1${count.index + 1}"
  })

  network_config = templatefile("${path.module}/network-config.yml", {
    ip_address = "10.10.10.1${count.index + 1}"
  })
}


resource "libvirt_cloudinit_disk" "worker_init" {
  count = 3
  name  = "k8s-worker-${count.index + 1}-init.iso"
  pool  = libvirt_pool.k8s_pool.name

  user_data = templatefile("${path.module}/cloud-init-worker.yml", {
    hostname = "k8s-worker-${count.index + 1}"
    ssh_key  = file(var.ssh_public_key_path)
    node_ip  = "10.10.10.2${count.index + 1}"
  })

  network_config = templatefile("${path.module}/network-config.yml", {
    ip_address = "10.10.10.2${count.index + 1}"
  })
}


# Master nodes
resource "libvirt_domain" "k8s_masters" {
  count  = 2
  name   = "k8s-master-${count.index + 1}"
  memory = "1024"  # 1GB RAM
  vcpu   = 1       # 4 vCPUs

  cloudinit = libvirt_cloudinit_disk.master_init[count.index].id

  network_interface {
    network_id     = libvirt_network.k8s_network.id
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.master_disks[count.index].id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

  # CPU configuration for better performance
  cpu {
    mode = "host-passthrough"
  }

  # Ensure proper startup order
  depends_on = [libvirt_network.k8s_network]
}

# Worker nodes
resource "libvirt_domain" "k8s_workers" {
  count  = 3
  name   = "k8s-worker-${count.index + 1}"
  memory = "24576"  # 24GB RAM
  vcpu   = 6        # 6 vCPUs

  cloudinit = libvirt_cloudinit_disk.worker_init[count.index].id

  network_interface {
    network_id     = libvirt_network.k8s_network.id
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.worker_disks[count.index].id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

  # CPU configuration for better performance
  cpu {
    mode = "host-passthrough"
  }

  # Ensure proper startup order
  depends_on = [libvirt_network.k8s_network]
}