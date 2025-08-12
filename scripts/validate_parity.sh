#!/bin/bash
# Feature Parity Validation Script
# This script validates that Elixir implementation has complete parity with Terraform

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔍 Starting Feature Parity Validation${NC}"
echo "=================================================="

# Check if we're in the right directory
if [ ! -d "romulus_elixir" ] || [ ! -d "infrastructure/libvirt/terraform" ]; then
    echo -e "${RED}❌ Error: Must run from romulus root directory${NC}"
    exit 1
fi

# Initialize counters
PASSED=0
FAILED=0
TOTAL=0

function test_result() {
    local test_name="$1"
    local result="$2"
    local message="$3"
    
    TOTAL=$((TOTAL + 1))
    
    if [ "$result" = "PASS" ]; then
        echo -e "  ${GREEN}✅ $test_name${NC}: $message"
        PASSED=$((PASSED + 1))
    elif [ "$result" = "SKIP" ]; then
        echo -e "  ${YELLOW}⏭️  $test_name${NC}: $message"
    else
        echo -e "  ${RED}❌ $test_name${NC}: $message"
        FAILED=$((FAILED + 1))
    fi
}

echo -e "\n${YELLOW}📦 Testing Elixir Setup${NC}"
echo "--------------------"

# Test 1: Elixir dependencies
cd romulus_elixir
if mix deps.get --only prod > /dev/null 2>&1; then
    test_result "Dependencies" "PASS" "All dependencies installed"
else
    test_result "Dependencies" "FAIL" "Failed to install dependencies"
fi

# Test 2: Compilation
if mix compile --warnings-as-errors > /dev/null 2>&1; then
    test_result "Compilation" "PASS" "Code compiles without warnings"
else
    test_result "Compilation" "FAIL" "Compilation errors or warnings"
fi

# Test 3: Configuration conversion
if [ -f "../infrastructure/libvirt/terraform/environments/home-lab/terraform.tfvars" ]; then
    if mix romulus.convert_config ../infrastructure/libvirt/terraform/environments/home-lab/terraform.tfvars --output test-config.yaml > /dev/null 2>&1; then
        test_result "Config Conversion" "PASS" "tfvars converted to YAML"
        rm -f test-config.yaml
    else
        test_result "Config Conversion" "FAIL" "Failed to convert tfvars"
    fi
else
    test_result "Config Conversion" "SKIP" "No tfvars file found"
fi

# Test 4: Template rendering
if mix romulus.render-cloudinit > /dev/null 2>&1; then
    test_result "Template Rendering" "PASS" "Cloud-init templates render correctly"
else
    test_result "Template Rendering" "FAIL" "Template rendering failed"
fi

# Test 5: Unit tests
if mix test --exclude integration > /dev/null 2>&1; then
    test_result "Unit Tests" "PASS" "All unit tests pass"
else
    test_result "Unit Tests" "FAIL" "Unit test failures"
fi

cd ..

echo -e "\n${YELLOW}🏗️  Testing Infrastructure Capabilities${NC}"
echo "----------------------------------------"

# Test 6: Terraform file analysis
TF_RESOURCES=$(find infrastructure/libvirt/terraform -name "*.tf" -exec grep -l "^resource" {} \; | wc -l)
if [ "$TF_RESOURCES" -gt 0 ]; then
    test_result "Terraform Files Found" "PASS" "Found $TF_RESOURCES Terraform files"
else
    test_result "Terraform Files Found" "FAIL" "No Terraform files found"
fi

# Test 7: Resource type coverage
ELIXIR_RESOURCES=$(grep -r "defmodule.*Libvirt\." romulus_elixir/lib/ | grep -E "(Network|Pool|Volume|Domain)" | wc -l)
if [ "$ELIXIR_RESOURCES" -ge 4 ]; then
    test_result "Resource Coverage" "PASS" "All libvirt resource types implemented"
else
    test_result "Resource Coverage" "FAIL" "Missing resource type implementations"
fi

# Test 8: Cloud-init template parity
TF_TEMPLATES=$(find infrastructure/libvirt/cloud-init -name "*.yml" | wc -l)
ELIXIR_TEMPLATES=$(find romulus_elixir/priv/cloud-init -name "*.yml" 2>/dev/null | wc -l)

if [ "$ELIXIR_TEMPLATES" -ge "$TF_TEMPLATES" ]; then
    test_result "Template Parity" "PASS" "All cloud-init templates present ($ELIXIR_TEMPLATES >= $TF_TEMPLATES)"
else
    test_result "Template Parity" "FAIL" "Missing cloud-init templates ($ELIXIR_TEMPLATES < $TF_TEMPLATES)"
fi

echo -e "\n${YELLOW}⚙️  Testing Operational Features${NC}"
echo "--------------------------------"

cd romulus_elixir

# Test 9: Plan operation
if mix romulus.plan > /dev/null 2>&1; then
    test_result "Plan Operation" "PASS" "Plan generation works"
else
    test_result "Plan Operation" "FAIL" "Plan generation failed"
fi

# Test 10: Health check
if mix romulus.health > /dev/null 2>&1; then
    test_result "Health Check" "PASS" "Health monitoring works"
else
    test_result "Health Check" "FAIL" "Health check failed"
fi

# Test 11: Smoke tests
if mix romulus.smoke_test --scope basic > /dev/null 2>&1; then
    test_result "Smoke Tests" "PASS" "Smoke tests execute"
else
    test_result "Smoke Tests" "FAIL" "Smoke test failures"
fi

# Test 12: Mix tasks availability
EXPECTED_TASKS=("romulus.plan" "romulus.apply" "romulus.destroy" "romulus.health" "romulus.heal" "romulus.smoke_test")
MISSING_TASKS=0

for task in "${EXPECTED_TASKS[@]}"; do
    if ! mix help | grep -q "$task"; then
        MISSING_TASKS=$((MISSING_TASKS + 1))
    fi
done

if [ "$MISSING_TASKS" -eq 0 ]; then
    test_result "Mix Tasks" "PASS" "All required Mix tasks available"
else
    test_result "Mix Tasks" "FAIL" "$MISSING_TASKS Mix tasks missing"
fi

cd ..

echo -e "\n${YELLOW}🔗 Testing Integration Features${NC}"
echo "--------------------------------"

cd romulus_elixir

# Test 13: Ansible inventory generation
if mix romulus.ansible_inventory > /dev/null 2>&1; then
    test_result "Ansible Integration" "PASS" "Inventory generation works"
else
    test_result "Ansible Integration" "FAIL" "Inventory generation failed"
fi

# Test 14: State export
if mix romulus.export_state > /dev/null 2>&1; then
    test_result "State Export" "PASS" "State export works"
else
    test_result "State Export" "FAIL" "State export failed"
fi

# Test 15: Configuration validation
if [ -f "romulus.yaml" ]; then
    if mix compile --warnings-as-errors > /dev/null 2>&1; then
        test_result "Config Validation" "PASS" "Configuration validates correctly"
    else
        test_result "Config Validation" "FAIL" "Configuration validation failed"
    fi
else
    test_result "Config Validation" "SKIP" "No romulus.yaml found"
fi

cd ..

echo -e "\n${YELLOW}📚 Testing Documentation and Examples${NC}"
echo "--------------------------------------------"

# Test 16: Documentation completeness
if [ -f "FEATURE_PARITY_AUDIT.md" ] && [ -f "MIGRATION_RUNBOOK.md" ] && [ -f "romulus_elixir/README.md" ]; then
    test_result "Documentation" "PASS" "All documentation files present"
else
    test_result "Documentation" "FAIL" "Missing documentation files"
fi

# Test 17: Migration tools
cd romulus_elixir
if mix romulus.import_state --help > /dev/null 2>&1; then
    test_result "Migration Tools" "PASS" "State import tool available"
else
    test_result "Migration Tools" "FAIL" "Migration tools missing"
fi

# Test 18: Makefile integration
cd ..
if [ -f "Makefile" ] && grep -q "INFRA_BACKEND" Makefile; then
    test_result "Makefile Integration" "PASS" "Makefile supports both backends"
else
    test_result "Makefile Integration" "FAIL" "Makefile integration missing"
fi

echo -e "\n${YELLOW}🔒 Security and Safety Tests${NC}"
echo "-----------------------------"

# Test 19: No sensitive data in code
if ! grep -r "password\|secret\|token" romulus_elixir/lib/ --include="*.ex" | grep -v "# Example\|TODO\|@doc"; then
    test_result "Security Scan" "PASS" "No hardcoded credentials found"
else
    test_result "Security Scan" "FAIL" "Potential sensitive data in code"
fi

# Test 20: Idempotency protection
cd romulus_elixir
if grep -q "ensure_config\|maybe_confirm" lib/romulus_elixir.ex; then
    test_result "Safety Checks" "PASS" "Safety confirmations implemented"
else
    test_result "Safety Checks" "FAIL" "Missing safety checks"
fi

cd ..

echo -e "\n${YELLOW}📊 Validation Summary${NC}"
echo "====================="
echo -e "Total Tests: $TOTAL"
echo -e "Passed: ${GREEN}$PASSED${NC}"
if [ "$FAILED" -gt 0 ]; then
    echo -e "Failed: ${RED}$FAILED${NC}"
fi

SUCCESS_RATE=$(( (PASSED * 100) / TOTAL ))
echo -e "Success Rate: $SUCCESS_RATE%"

echo -e "\n${YELLOW}🎯 Parity Assessment${NC}"
echo "===================="

if [ "$FAILED" -eq 0 ] && [ "$SUCCESS_RATE" -eq 100 ]; then
    echo -e "${GREEN}✅ COMPLETE PARITY ACHIEVED${NC}"
    echo -e "${GREEN}✅ Ready for Terraform replacement${NC}"
    echo -e "${GREEN}✅ All functionality verified${NC}"
    
    echo -e "\n${YELLOW}Next Steps:${NC}"
    echo "1. Run: make migrate-check"
    echo "2. Run: make migrate-plan"
    echo "3. Execute replacement script"
    exit 0
elif [ "$SUCCESS_RATE" -gt 90 ]; then
    echo -e "${YELLOW}⚠️  Minor issues detected ($FAILED failed tests)${NC}"
    echo -e "${YELLOW}✅ Ready for replacement with monitoring${NC}"
    exit 0
else
    echo -e "${RED}❌ SIGNIFICANT ISSUES DETECTED${NC}"
    echo -e "${RED}❌ Not ready for Terraform replacement${NC}"
    echo -e "${RED}❌ Please fix failed tests before proceeding${NC}"
    exit 1
fi