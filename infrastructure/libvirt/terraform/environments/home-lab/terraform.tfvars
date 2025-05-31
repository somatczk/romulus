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
master_memory = 1024  # 1GB
master_vcpu   = 1

# Worker node resources
worker_memory = 18432  # 18GB
worker_vcpu   = 6

# Disk sizes
master_disk_size = 53687091200  # 50GB
worker_disk_size = 107374182400  # 100GB    

# SSH key for accessing VMs
ssh_public_key_path ="/etc/ssh/ssh_host_rsa_key.pub"

# Base image - Debian 12
base_image_url = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2"