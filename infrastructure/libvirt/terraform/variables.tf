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
  default     = "~/.ssh/id_rsa.pub"
}

variable "base_image_url" {
  description = "URL of the base image"
  type        = string
  default     = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2"
}