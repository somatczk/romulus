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