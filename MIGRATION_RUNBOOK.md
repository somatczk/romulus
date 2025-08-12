# Romulus Migration Runbook: Terraform → Elixir

## Executive Summary

This runbook provides step-by-step instructions for migrating from the Terraform-based infrastructure to the new Elixir implementation. The migration is designed to be **safe**, **reversible**, and **zero-downtime**.

## Migration Timeline

- **Preparation**: 2-4 hours
- **Validation**: 1-2 hours  
- **Migration**: 30 minutes (if infrastructure exists) or 2-3 hours (fresh deployment)
- **Verification**: 1 hour
- **Total**: 4-8 hours

## Prerequisites

### Team Requirements
- [ ] Infrastructure team member present
- [ ] Kubernetes admin available
- [ ] Network team on standby
- [ ] Backup verification completed

### Technical Requirements
- [ ] Elixir 1.17+ installed
- [ ] Current Terraform state backed up
- [ ] libvirt access verified
- [ ] SSH keys in place

## Phase 1: Preparation (2-4 hours)

### Step 1.1: Backup Current State
```bash
# Create backup directory
mkdir -p backups/migration-$(date +%Y%m%d)
cd backups/migration-$(date +%Y%m%d)

# Backup Terraform state
cp infrastructure/libvirt/terraform/terraform.tfstate* .

# Export current infrastructure state
cd infrastructure/libvirt/terraform
terraform show -json > terraform-state-export.json

# Backup Kubernetes configs
kubectl get all --all-namespaces -o yaml > k8s-all-resources.yaml
kubectl get pv,pvc --all-namespaces -o yaml > k8s-storage.yaml

# Document current running VMs
virsh list --all > virsh-domains.txt
virsh net-list --all > virsh-networks.txt
virsh pool-list --all > virsh-pools.txt
```

### Step 1.2: Setup Elixir Environment
```bash
# Install dependencies
cd romulus_elixir
mix deps.get
mix compile

# Run tests to verify environment
mix test

# Verify Mix tasks are available
mix help | grep romulus
```

### Step 1.3: Convert Configuration
```bash
# Auto-convert Terraform variables
mix romulus.convert_config \
  ../infrastructure/libvirt/terraform/environments/home-lab/terraform.tfvars \
  --output romulus.yaml

# Review and adjust the generated config
vim romulus.yaml

# Validate configuration
mix romulus.render-cloudinit
```

## Phase 2: Validation (1-2 hours)

### Step 2.1: Pre-Migration Checks
```bash
# Run migration readiness check
make migrate-check

# Expected output:
# ✓ Terraform state: X resources
# ✓ Elixir dependencies installed
# ✓ Config file exists
# ✓ Existing VMs found (or not)
# Ready for migration!
```

### Step 2.2: Import and Analyze State
```bash
# Import Terraform state for analysis
cd romulus_elixir
mix romulus.import_state --tfstate ../infrastructure/libvirt/terraform/terraform.tfstate

# Review the analysis report
# Pay attention to:
# - Matched resources (should be all if infra exists)
# - Missing resources (should be none)
# - Validation errors (must be resolved)
```

### Step 2.3: Plan Comparison
```bash
# Compare plans between Terraform and Elixir
make migrate-plan

# Both should show "No changes" if infrastructure exists
# Or similar "create" actions if starting fresh
```

## Phase 3: Migration (30 min - 3 hours)

### Option A: Existing Infrastructure (30 minutes)

If you have running infrastructure managed by Terraform:

```bash
# Step 1: Verify Elixir sees current state correctly
cd romulus_elixir
mix romulus.plan

# Should output: "Infrastructure is up to date. No changes needed."

# Step 2: Test idempotency
ROMULUS_AUTO_APPROVE=true mix romulus.apply

# Should complete with no changes

# Step 3: Switch default backend
export INFRA_BACKEND=elixir
echo "INFRA_BACKEND=elixir" >> ~/.bashrc

# Step 4: Verify management
make plan  # Now uses Elixir
```

### Option B: Fresh Deployment (2-3 hours)

If deploying fresh infrastructure:

```bash
# Step 1: Ensure clean state
make destroy INFRA_BACKEND=terraform  # If any Terraform resources exist

# Step 2: Deploy with Elixir
cd romulus_elixir
mix romulus.plan

# Review the plan carefully
# Should show creation of all resources

# Step 3: Apply infrastructure
mix romulus.apply

# Monitor progress
watch -n 5 'virsh list --all'

# Step 4: Verify deployment
mix romulus.plan
# Should show: "Infrastructure is up to date"
```

## Phase 4: Kubernetes Bootstrap (1 hour)

### Step 4.1: Bootstrap Cluster
```bash
# Only if fresh deployment or cluster needs setup
mix romulus.k8s.bootstrap

# Wait for completion
kubectl wait --for=condition=Ready nodes --all --timeout=600s
```

### Step 4.2: Verify Cluster
```bash
# Check nodes
kubectl get nodes

# Check system pods
kubectl get pods -n kube-system

# Run test pod
kubectl run test --image=nginx --restart=Never
kubectl wait --for=condition=Ready pod/test
kubectl delete pod test
```

## Phase 5: Verification (1 hour)

### Step 5.1: Infrastructure Tests
```bash
# Run integration tests
cd romulus_elixir
mix test.integration

# Check resource status
make metrics
```

### Step 5.2: Generate Ansible Inventory
```bash
# Generate inventory for Ansible integration
mix romulus.ansible_inventory --format yaml \
  --output ../infrastructure/ansible/inventories/home-lab/hosts.yml

# Verify Ansible connectivity
cd ../infrastructure/ansible
ansible all -i inventories/home-lab/hosts.yml -m ping
```

### Step 5.3: Application Validation
```bash
# Deploy test application
kubectl apply -f tests/kubernetes/smoke-tests/nginx-test.yaml

# Verify application is running
kubectl get pods -l app=nginx-test
kubectl port-forward deployment/nginx-test 8080:80 &

# Test connectivity
curl http://localhost:8080

# Cleanup
kill %1  # Stop port-forward
kubectl delete -f tests/kubernetes/smoke-tests/nginx-test.yaml
```

## Phase 6: Cutover

### Step 6.1: Update Documentation
```bash
# Update README to reflect Elixir as primary
vim README.md
# Change: "Infrastructure is managed by Terraform"
# To: "Infrastructure is managed by Romulus Elixir"

# Update team runbooks
vim documentation/runbooks/cluster-bootstrap.md
# Update commands from terraform to mix romulus.*
```

### Step 6.2: Update CI/CD
```yaml
# .github/workflows/infrastructure.yml
- name: Plan Infrastructure
  run: |
    cd romulus_elixir
    mix romulus.plan
    
- name: Apply Infrastructure
  if: github.ref == 'refs/heads/main'
  run: |
    cd romulus_elixir
    ROMULUS_AUTO_APPROVE=true mix romulus.apply
```

### Step 6.3: Team Communication
```markdown
To: infrastructure-team@example.com
Subject: Infrastructure Management Migration Complete

Team,

We have successfully migrated from Terraform to Romulus Elixir for infrastructure management.

Key changes:
- Use `make plan/apply/destroy` (automatically uses Elixir backend)
- Or directly: `cd romulus_elixir && mix romulus.*`
- Configuration now in `romulus_elixir/romulus.yaml`
- No state files - queries libvirt directly
- Rollback possible: `export INFRA_BACKEND=terraform`

Documentation: romulus_elixir/docs/
Support: #infrastructure-help

Thanks,
DevOps Team
```

## Rollback Procedure

If issues arise, rollback to Terraform:

### Quick Rollback (5 minutes)
```bash
# Switch back to Terraform
export INFRA_BACKEND=terraform

# Verify Terraform still works
cd infrastructure/libvirt/terraform
terraform plan -var-file=environments/home-lab/terraform.tfvars

# Should show no changes if infrastructure unchanged
```

### Full Rollback (30 minutes)
```bash
# If Elixir made changes that need reverting

# Step 1: Export current state from Elixir
cd romulus_elixir
mix romulus.export_state > current-state.json

# Step 2: Destroy via Elixir if needed
mix romulus.destroy

# Step 3: Restore via Terraform
cd ../infrastructure/libvirt/terraform
terraform apply -var-file=environments/home-lab/terraform.tfvars

# Step 4: Verify restoration
terraform plan  # Should show no changes
```

## Troubleshooting

### Issue: "Resources in Terraform but not in libvirt"
```bash
# Sync Terraform state with reality
cd infrastructure/libvirt/terraform
terraform refresh
terraform plan

# If resources truly missing, recreate
terraform apply -target=libvirt_domain.k8s_masters
```

### Issue: "Elixir plan shows unexpected changes"
```bash
# Debug state comparison
cd romulus_elixir
export ROMULUS_LOG_LEVEL=debug
mix romulus.plan

# Check libvirt directly
virsh list --all
virsh net-list --all
virsh pool-list --all
```

### Issue: "Mix tasks not found"
```bash
# Recompile
mix clean
mix deps.get
mix compile

# Verify tasks
mix help | grep romulus
```

### Issue: "Permission denied on libvirt"
```bash
# Fix permissions
sudo usermod -aG libvirt $USER
newgrp libvirt

# Verify access
virsh list --all
```

## Success Criteria

Migration is successful when:

- [ ] All infrastructure resources are manageable via Elixir
- [ ] `mix romulus.plan` shows no unexpected changes
- [ ] Kubernetes cluster is healthy
- [ ] Applications are running normally
- [ ] Team can perform standard operations
- [ ] Rollback procedure is tested and documented

## Post-Migration Tasks

### Week 1
- [ ] Monitor for any issues
- [ ] Gather team feedback
- [ ] Update any remaining documentation
- [ ] Remove Terraform deprecation notices

### Week 2
- [ ] Performance comparison report
- [ ] Cost analysis (if applicable)
- [ ] Team training session
- [ ] Update disaster recovery procedures

### Month 1
- [ ] Full DR drill using Elixir
- [ ] Optimize configuration based on usage
- [ ] Archive Terraform code (keep for reference)
- [ ] Success retrospective

## Support

- **Slack**: #romulus-migration
- **Docs**: romulus_elixir/docs/
- **Issues**: GitHub Issues
- **Escalation**: infrastructure-oncall@example.com

## Appendix: Command Reference

### Terraform (Old)
```bash
terraform plan
terraform apply
terraform destroy
terraform state list
terraform output
```

### Elixir (New)
```bash
mix romulus.plan
mix romulus.apply
mix romulus.destroy
mix romulus.export_state
mix romulus.ansible_inventory
```

### Makefile (Works with both)
```bash
make plan      # Uses $INFRA_BACKEND
make apply     # Uses $INFRA_BACKEND
make destroy   # Uses $INFRA_BACKEND
make migrate-check
make migrate-plan
```

---

**Migration Completed By**: ________________  
**Date**: ________________  
**Verified By**: ________________  
**Rollback Tested**: [ ] Yes [ ] No  
**Documentation Updated**: [ ] Yes [ ] No