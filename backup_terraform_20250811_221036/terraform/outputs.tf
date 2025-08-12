# Output values from your Terraform configuration
# Example:
# output "example_output" {
#   description = "An example output"
#   value       = resource.name.id
# } 

# Output the IP addresses of master nodes
output "master_ips" {
  description = "IP addresses of master nodes"
  value = {
    for i, master in libvirt_domain.k8s_masters :
    master.name => master.network_interface[0].addresses[0]
  }
}

# Output the IP addresses of worker nodes
output "worker_ips" {
  description = "IP addresses of worker nodes"
  value = {
    for i, worker in libvirt_domain.k8s_workers :
    worker.name => worker.network_interface[0].addresses[0]
  }
}

# Complete cluster information
output "cluster_info" {
  description = "Complete cluster configuration and connection information"
  value = {
    network_cidr = "10.10.10.0/24"
    masters = [
      for i in range(2) : {
        name = "k8s-master-${i + 1}"
        ip   = "10.10.10.1${i + 1}"
        ssh  = "ssh debian@10.10.10.1${i + 1}"
      }
    ]
    workers = [
      for i in range(3) : {
        name = "k8s-worker-${i + 1}"
        ip   = "10.10.10.2${i + 1}"
        ssh  = "ssh debian@10.10.10.2${i + 1}"
      }
    ]
  }
}

# SSH commands for easy access
output "ssh_commands" {
  description = "Ready-to-use SSH commands"
  value = {
    masters = [
      for i in range(2) :
      "ssh debian@10.10.10.1${i + 1}"
    ]
    workers = [
      for i in range(3) :
      "ssh debian@10.10.10.2${i + 1}"
    ]
  }
} 