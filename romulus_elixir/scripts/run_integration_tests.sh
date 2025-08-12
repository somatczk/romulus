#!/bin/bash
# Enhanced Libvirt Integration Tests Runner
# This script sets up the environment and runs comprehensive libvirt integration tests

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧪 Enhanced Libvirt Integration Tests${NC}"
echo "======================================"

# Check prerequisites
echo -e "\n${YELLOW}📋 Checking Prerequisites${NC}"
echo "-------------------------"

# Check if libvirt is available
if ! command -v virsh &> /dev/null; then
    echo -e "${RED}❌ Error: virsh not found. Please install libvirt.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ virsh found${NC}"
fi

# Check if virsh can connect
if ! virsh version &> /dev/null; then
    echo -e "${RED}❌ Error: Cannot connect to libvirt. Is libvirtd running?${NC}"
    echo "Try: sudo systemctl start libvirtd"
    exit 1
else
    echo -e "${GREEN}✅ libvirt connection OK${NC}"
fi

# Check if user is in libvirt group (Linux/Unix systems)
if [[ "$OSTYPE" == "linux-gnu"* ]] || [[ "$OSTYPE" == "freebsd"* ]]; then
    if ! groups | grep -q libvirt; then
        echo -e "${YELLOW}⚠️  Warning: User not in libvirt group. Some tests may fail.${NC}"
        echo "To fix: sudo usermod -aG libvirt \$USER && newgrp libvirt"
    else
        echo -e "${GREEN}✅ User in libvirt group${NC}"
    fi
fi

# Check available system resources
echo -e "\n${YELLOW}💻 System Resources${NC}"
echo "-------------------"
echo "Available disk space: $(df -h /tmp | tail -1 | awk '{print $4}')"
echo "Available memory: $(free -h | grep '^Mem:' | awk '{print $7}' 2>/dev/null || echo 'N/A')"

# Set environment variables for testing
export MIX_ENV=test
export ROMULUS_LOG_LEVEL=info
export ROMULUS_CLEANUP_LIBVIRT=true

# Clean up any existing test resources
echo -e "\n${YELLOW}🧹 Cleaning up existing test resources${NC}"
echo "--------------------------------------"

# Clean up test networks
for net in $(virsh net-list --all --name 2>/dev/null | grep "^test-" || true); do
    echo "Cleaning up test network: $net"
    virsh net-destroy "$net" 2>/dev/null || true
    virsh net-undefine "$net" 2>/dev/null || true
done

# Clean up test pools
for pool in $(virsh pool-list --all --name 2>/dev/null | grep "^test-" || true); do
    echo "Cleaning up test pool: $pool"
    # Delete volumes first
    for vol in $(virsh vol-list "$pool" --name 2>/dev/null || true); do
        virsh vol-delete "$vol" --pool "$pool" 2>/dev/null || true
    done
    virsh pool-destroy "$pool" 2>/dev/null || true
    virsh pool-undefine "$pool" 2>/dev/null || true
done

# Clean up test domains
for domain in $(virsh list --all --name 2>/dev/null | grep "^test-" || true); do
    echo "Cleaning up test domain: $domain"
    virsh destroy "$domain" 2>/dev/null || true
    virsh undefine "$domain" --remove-all-storage 2>/dev/null || true
done

# Clean up test directories
echo "Cleaning up test directories..."
rm -rf /tmp/test-*pool* 2>/dev/null || true
rm -rf /tmp/test-*attach* 2>/dev/null || true
rm -rf /var/tmp/test-pool* 2>/dev/null || true

echo -e "${GREEN}✅ Cleanup completed${NC}"

# Run the tests
echo -e "\n${YELLOW}🚀 Running Enhanced Integration Tests${NC}"
echo "======================================"

# Test categories to run
TESTS=(
    "Infrastructure Lifecycle"
    "Network Management"
    "Storage Management" 
    "Multi-Node Scenarios"
    "Concurrent Operations"
    "Volume Attach/Detach"
    "Network Failure Simulation"
    "Parametrized CIDR Tests"
    "Parametrized Storage Pool Tests"
    "Stress Testing"
)

echo -e "${BLUE}Test Categories:${NC}"
for test in "${TESTS[@]}"; do
    echo "  • $test"
done

echo -e "\n${YELLOW}Starting test execution...${NC}"

# Run the actual tests
if mix test test/integration/libvirt_integration_test.exs --include integration --timeout 600000; then
    echo -e "\n${GREEN}🎉 All Enhanced Integration Tests Passed!${NC}"
    echo -e "${GREEN}✅ Multi-node scenarios: Working${NC}"
    echo -e "${GREEN}✅ Concurrent operations: Working${NC}" 
    echo -e "${GREEN}✅ Volume attach/detach: Working${NC}"
    echo -e "${GREEN}✅ Network failure simulation: Working${NC}"
    echo -e "${GREEN}✅ Parametrized tests: Working${NC}"
    echo -e "${GREEN}✅ Self-healing verification: Working${NC}"
    
    echo -e "\n${YELLOW}📊 Test Coverage Summary${NC}"
    echo "========================"
    echo "• ✅ Basic infrastructure lifecycle"
    echo "• ✅ Multi-master cluster deployment (3 masters + 2 workers)"
    echo "• ✅ Node failure and recovery simulation"
    echo "• ✅ Concurrent resource creation (pools, networks)"
    echo "• ✅ Volume hot-attach and hot-detach"
    echo "• ✅ Network partition simulation with iptables"
    echo "• ✅ DNS failure and recovery"
    echo "• ✅ Multiple CIDR ranges (10.x, 172.x, 192.168.x)"
    echo "• ✅ Different storage pool types and paths"
    echo "• ✅ Rapid resource creation/deletion cycles"
    echo "• ✅ Resource exhaustion handling"
    echo "• ✅ Self-healing mechanisms"
    
    exit 0
else
    echo -e "\n${RED}❌ Some Integration Tests Failed${NC}"
    echo -e "${RED}Please check the test output above for details.${NC}"
    
    echo -e "\n${YELLOW}💡 Troubleshooting Tips:${NC}"
    echo "• Check if libvirtd is running: sudo systemctl status libvirtd"
    echo "• Verify user permissions: groups | grep libvirt"
    echo "• Check available resources: df -h /tmp && free -h"
    echo "• Review logs: journalctl -u libvirtd --no-pager"
    echo "• For network tests, ensure iptables is available"
    echo "• Some tests may require root privileges for iptables manipulation"
    
    exit 1
fi
