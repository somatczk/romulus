# Home Lab environment variables
# Example:
# vm_count = 3
# memory_size = 4096
# cpu_count = 2 

# Home Lab Environment Configuration

# Cluster sizing
master_count = 2
worker_count = 3

# Master node resources (minimum for k8s)
master_memory = 4096  # 4GB
master_vcpu   = 2

# Worker node resources
worker_memory = 8192  # 8GB
worker_vcpu   = 4

# SSH key for accessing VMs
ssh_public_key_path = "~/.ssh/id_rsa.pub"

# Base image - Debian 12
base_image_url = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2"