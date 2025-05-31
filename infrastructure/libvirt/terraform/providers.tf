# Provider configuration
# Example:
# terraform {
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 4.0"
#     }
#   }
# }
# 
# provider "aws" {
#   region = "us-west-2"
# } 

terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.3"
    }
  }
  required_version = ">= 1.0.0"
}