# Input variables for your Terraform configuration
# Example:
# variable "example_variable" {
#   description = "An example variable"
#   type        = string
#   default     = "default_value"
# } 


variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "/etc/ssh/ssh_host_rsa_key.pub"
}

variable "base_image_url" {
  description = "URL of the base image"
  type        = string
}

variable "master_count" {
  description = "Number of master nodes"
  type        = number
  default     = 2
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "master_memory" {
  description = "Memory for master nodes"
  type        = number
  default     = 1024
}

variable "worker_memory" {
  description = "Memory for worker nodes"
  type        = number
  default     = 18432
}

variable "master_vcpu" {
  description = "vCPUs for master nodes"
  type        = number
  default     = 1
}

variable "worker_vcpu" {
  description = "vCPUs for worker nodes"
  type        = number
  default     = 4
}

variable "master_disk_size" {
  description = "Disk size for master nodes"
  type        = number
  default     = 53687091200
}

variable "worker_disk_size" {
  description = "Disk size for worker nodes"
  type        = number
  default     = 107374182400
}