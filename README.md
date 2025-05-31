# Home Lab Kubernetes Infrastructure

This repository contains the infrastructure as code and configuration for a home lab Kubernetes cluster using libvirt.

## Repository Structure

### Infrastructure
- `infrastructure/libvirt/`: VM infrastructure using libvirt
  - `terraform/`: Terraform configurations for provisioning VMs
  - `cloud-init/`: Cloud-init templates for VM configuration

### Kubernetes
- `kubernetes/bootstrap/`: Initial cluster setup
- `kubernetes/core/`: Core components (networking, storage, etc.)
- `kubernetes/platform/`: Platform services (monitoring, logging, etc.)
- `kubernetes/applications/`: Application deployments
- `kubernetes/security/`: Security configurations and policies

### Documentation
- `documentation/architecture/`: Architecture documentation
- `documentation/runbooks/`: Operational runbooks
- `documentation/diagrams/`: Architecture diagrams

### CI/CD
- `.github/workflows/`: GitHub Actions workflows

## Getting Started

1. Set up libvirt infrastructure:
```
cd infrastructure/libvirt/terraform
terraform init
terraform apply
```

2. Configure and bootstrap the Kubernetes cluster following the runbooks in the documentation folder.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines. 