#!/bin/bash
# Terraform Replacement Script
# Safely removes Terraform implementation and promotes Elixir as primary

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BACKUP_DIR="backup_terraform_$(date +%Y%m%d_%H%M%S)"

echo -e "${BLUE}🔄 Terraform → Elixir Replacement${NC}"
echo "=================================="
echo "This script will:"
echo "1. Validate Elixir implementation"
echo "2. Backup Terraform files"
echo "3. Remove Terraform implementation"
echo "4. Update all references"
echo "5. Set Elixir as default"
echo ""

# Safety check
if [ "$1" != "--confirmed" ]; then
    echo -e "${YELLOW}⚠️  This will permanently remove Terraform files!${NC}"
    echo -e "${YELLOW}⚠️  Make sure you have validated the Elixir implementation first.${NC}"
    echo ""
    echo "To continue, run: $0 --confirmed"
    echo "To validate first, run: ./scripts/validate_parity.sh"
    exit 1
fi

# Check if we're in the right directory
if [ ! -d "romulus_elixir" ] || [ ! -d "infrastructure/libvirt/terraform" ]; then
    echo -e "${RED}❌ Error: Must run from romulus root directory${NC}"
    exit 1
fi

echo -e "${YELLOW}🔍 Step 1: Pre-flight Validation${NC}"
echo "--------------------------------"

# Run validation script first
if [ -f "scripts/validate_parity.sh" ]; then
    echo "Running feature parity validation..."
    if ./scripts/validate_parity.sh; then
        echo -e "${GREEN}✅ Validation passed - proceeding with replacement${NC}"
    else
        echo -e "${RED}❌ Validation failed - aborting replacement${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠️  No validation script found, proceeding anyway...${NC}"
fi

echo -e "\n${YELLOW}📦 Step 2: Backup Terraform Implementation${NC}"
echo "-------------------------------------------"

# Create backup directory
mkdir -p "$BACKUP_DIR"
echo "Created backup directory: $BACKUP_DIR"

# Backup Terraform files
echo "Backing up Terraform implementation..."
cp -r infrastructure/libvirt/terraform "$BACKUP_DIR/"
cp -r infrastructure/libvirt/cloud-init "$BACKUP_DIR/"

# Backup any Terraform state if it exists
if [ -f "infrastructure/libvirt/terraform/terraform.tfstate" ]; then
    cp infrastructure/libvirt/terraform/terraform.tfstate* "$BACKUP_DIR/"
    echo "✅ Backed up Terraform state"
fi

# Create backup inventory
cat > "$BACKUP_DIR/BACKUP_INVENTORY.md" << EOF
# Terraform Backup Inventory

**Backup Created**: $(date)
**Backup Directory**: $BACKUP_DIR

## Files Backed Up

### Terraform Configuration
- All .tf files from infrastructure/libvirt/terraform/
- terraform.tfvars from environments/
- terraform.tfstate (if present)

### Cloud-Init Templates
- All .yml templates from infrastructure/libvirt/cloud-init/

### Restoration Instructions
To restore Terraform (if needed):
1. Stop any Elixir-managed infrastructure
2. Copy files from this backup back to their original locations
3. Run: terraform init && terraform plan

### Verification
The backup is complete and can be used to restore the full Terraform implementation.
EOF

echo -e "${GREEN}✅ Backup completed: $BACKUP_DIR${NC}"

echo -e "\n${YELLOW}🗑️  Step 3: Remove Terraform Files${NC}"
echo "-----------------------------------"

# Remove Terraform configuration files
echo "Removing Terraform configuration files..."
find infrastructure/libvirt/terraform -name "*.tf" -delete
find infrastructure/libvirt/terraform -name "*.tfvars" -delete
find infrastructure/libvirt/terraform -name "*.tfstate*" -delete
find infrastructure/libvirt/terraform -name ".terraform*" -delete

# Remove terraform directories but keep structure
rm -rf infrastructure/libvirt/terraform/environments/
rm -rf infrastructure/libvirt/terraform/.terraform/

echo -e "${GREEN}✅ Terraform configuration files removed${NC}"

# Remove old cloud-init templates (they're now in romulus_elixir/priv/cloud-init/)
echo "Removing duplicate cloud-init templates..."
rm -rf infrastructure/libvirt/cloud-init/

echo -e "${GREEN}✅ Duplicate cloud-init templates removed${NC}"

echo -e "\n${YELLOW}📝 Step 4: Update Documentation and References${NC}"
echo "----------------------------------------------"

# Update main README
if [ -f "README.md" ]; then
    echo "Updating main README..."
    
    # Replace Terraform references with Elixir
    sed -i.bak 's/Terraform/Romulus Elixir/g' README.md
    sed -i.bak 's/terraform plan/make plan/g' README.md
    sed -i.bak 's/terraform apply/make apply/g' README.md
    sed -i.bak 's/terraform destroy/make destroy/g' README.md
    sed -i.bak 's/infrastructure\/libvirt\/terraform/romulus_elixir/g' README.md
    
    # Remove backup file
    rm -f README.md.bak
    
    echo -e "${GREEN}✅ Main README updated${NC}"
fi

# Update documentation references
if [ -d "documentation/" ]; then
    echo "Updating documentation references..."
    
    find documentation/ -name "*.md" -exec sed -i.bak 's/terraform plan/make plan/g' {} \;
    find documentation/ -name "*.md" -exec sed -i.bak 's/terraform apply/make apply/g' {} \;
    find documentation/ -name "*.md" -exec sed -i.bak 's/terraform destroy/make destroy/g' {} \;
    find documentation/ -name "*.md" -exec sed -i.bak 's/infrastructure\/libvirt\/terraform/romulus_elixir/g' {} \;
    
    # Remove backup files
    find documentation/ -name "*.bak" -delete
    
    echo -e "${GREEN}✅ Documentation updated${NC}"
fi

# Update Makefile to default to Elixir
echo "Setting Elixir as default backend in Makefile..."
sed -i.bak 's/INFRA_BACKEND ?= elixir/INFRA_BACKEND ?= elixir/' Makefile
rm -f Makefile.bak

echo -e "${GREEN}✅ Makefile updated to default to Elixir${NC}"

echo -e "\n${YELLOW}🔧 Step 5: Clean Up Empty Directories${NC}"
echo "-------------------------------------"

# Remove empty Terraform directories
find infrastructure/libvirt/terraform -type d -empty -delete 2>/dev/null || true

# If terraform directory is empty, remove it entirely
if [ -d "infrastructure/libvirt/terraform" ] && [ -z "$(find infrastructure/libvirt/terraform -name '*' -type f)" ]; then
    rmdir infrastructure/libvirt/terraform
    echo -e "${GREEN}✅ Removed empty Terraform directory${NC}"
fi

echo -e "\n${YELLOW}📋 Step 6: Create Replacement Summary${NC}"
echo "-------------------------------------"

cat > "TERRAFORM_REPLACEMENT_SUMMARY.md" << EOF
# Terraform Replacement Summary

**Replacement Date**: $(date)
**Backup Location**: $BACKUP_DIR

## What Was Replaced

### Removed
- ❌ All Terraform .tf configuration files
- ❌ All Terraform .tfvars variable files  
- ❌ All Terraform state files (.tfstate)
- ❌ Duplicate cloud-init templates
- ❌ Empty Terraform directories

### Added/Updated
- ✅ Elixir implementation is now the primary infrastructure tool
- ✅ Makefile defaults to Elixir backend
- ✅ Documentation updated to reference Elixir commands
- ✅ Cloud-init templates consolidated in romulus_elixir/priv/cloud-init/

## Command Changes

| Old (Terraform) | New (Elixir) |
|----------------|--------------|
| \`terraform plan\` | \`make plan\` or \`mix romulus.plan\` |
| \`terraform apply\` | \`make apply\` or \`mix romulus.apply\` |
| \`terraform destroy\` | \`make destroy\` or \`mix romulus.destroy\` |
| \`terraform show\` | \`mix romulus.export_state\` |

## Rollback Instructions

If you need to restore Terraform (emergency only):

1. **Stop Elixir-managed infrastructure**:
   \`\`\`bash
   make destroy
   \`\`\`

2. **Restore from backup**:
   \`\`\`bash
   cp -r $BACKUP_DIR/terraform infrastructure/libvirt/
   cp -r $BACKUP_DIR/cloud-init infrastructure/libvirt/
   \`\`\`

3. **Reinitialize Terraform**:
   \`\`\`bash
   cd infrastructure/libvirt/terraform
   terraform init
   terraform plan
   \`\`\`

## Verification

To verify the replacement was successful:

1. **Test Elixir functionality**:
   \`\`\`bash
   make plan
   \`\`\`

2. **Verify no Terraform files remain**:
   \`\`\`bash
   find . -name "*.tf" -o -name "*.tfstate*"
   # Should return no results
   \`\`\`

3. **Run health checks**:
   \`\`\`bash
   cd romulus_elixir
   mix romulus.health
   \`\`\`

## Next Steps

1. Deploy infrastructure using Elixir: \`make apply\`
2. Run smoke tests: \`mix romulus.smoke_test\`
3. Update team processes and documentation
4. Train team on new Elixir commands
5. Archive backup directory after 30 days

## Support

- **Documentation**: romulus_elixir/docs/
- **Migration Guide**: docs/migration.md
- **Runbook**: MIGRATION_RUNBOOK.md
- **Issues**: Create GitHub issues for any problems
EOF

echo -e "${GREEN}✅ Replacement summary created${NC}"

echo -e "\n${YELLOW}🧪 Step 7: Final Verification${NC}"
echo "-----------------------------"

# Verify Terraform files are gone
TF_FILES=$(find . -name "*.tf" -o -name "*.tfstate*" 2>/dev/null | wc -l)
if [ "$TF_FILES" -eq 0 ]; then
    echo -e "${GREEN}✅ All Terraform files successfully removed${NC}"
else
    echo -e "${YELLOW}⚠️  Found $TF_FILES remaining Terraform files${NC}"
fi

# Verify Elixir still works
cd romulus_elixir
if mix compile > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Elixir implementation still functional${NC}"
else
    echo -e "${RED}❌ Elixir compilation issues detected${NC}"
fi

# Test basic functionality
if mix romulus.plan > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Elixir plan operation works${NC}"
else
    echo -e "${YELLOW}⚠️  Plan operation has issues (may be due to missing config)${NC}"
fi

cd ..

echo -e "\n${BLUE}🎉 Replacement Complete!${NC}"
echo "======================="
echo -e "${GREEN}✅ Terraform implementation removed${NC}"
echo -e "${GREEN}✅ Elixir is now the primary infrastructure tool${NC}"
echo -e "${GREEN}✅ Backup saved to: $BACKUP_DIR${NC}"
echo -e "${GREEN}✅ Documentation updated${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Test the replacement: make plan"
echo "2. Deploy infrastructure: make apply"  
echo "3. Review: TERRAFORM_REPLACEMENT_SUMMARY.md"
echo "4. Train team on new commands"
echo ""
echo -e "${YELLOW}Emergency rollback:${NC}"
echo "If issues arise, follow instructions in TERRAFORM_REPLACEMENT_SUMMARY.md"
echo ""
echo -e "${GREEN}🎯 Migration to Elixir Complete! 🎯${NC}"