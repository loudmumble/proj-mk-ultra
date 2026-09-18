#!/usr/bin/env bash
# check-multikernel.sh - Verify multikernel is installed and configured
# SUSPICIOUS Framework: Pre-Installation Check
#
# Verifies:
# - Multikernel kernel is installed
# - Multikernel modules are available
# - Multikernel sysfs is mountable
# - Required kernel config options are enabled
#
# Usage: sudo ./check-multikernel.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         MULTIKERNEL INSTALLATION VERIFICATION                      ║
║         SUSPICIOUS Framework Pre-Installation Check                 ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Function to display test result
show_result() {
    local test_name="$1"
    local result="$2"
    local details="${3:-}"
    
    case "${result}" in
        PASS)
            echo -e "  ${GREEN}✓ ${test_name}${NC}"
            PASSED=$((PASSED + 1))
            ;;
        FAIL)
            echo -e "  ${RED}✗ ${test_name}${NC}"
            if [ -n "${details}" ]; then
                echo -e "    ${RED}${details}${NC}"
            fi
            FAILED=$((FAILED + 1))
            ;;
        WARN)
            echo -e "  ${YELLOW}⚠ ${test_name}${NC}"
            if [ -n "${details}" ]; then
                echo -e "    ${YELLOW}${details}${NC}"
            fi
            WARNINGS=$((WARNINGS + 1))
            ;;
    esac
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${BOLD}[ERROR] This script must be run as root${NC}"
        exit 1
    fi
}

# Function to check kernel version
check_kernel_version() {
    echo -e "\n${BOLD}Checking kernel version...${NC}"
    
    local kernel_version
    kernel_version=$(uname -r)
    
    if echo "${kernel_version}" | grep -iE "multikernel|mk2" > /dev/null; then
        show_result "Multikernel kernel detected: ${kernel_version}" "PASS"
    else
        show_result "Multikernel kernel NOT detected" "FAIL" "Current kernel: ${kernel_version}"
    fi
}

# Function to check kernel config
check_kernel_config() {
    echo -e "\n${BOLD}Checking kernel configuration...${NC}"
    
    local config_file="/proc/config.gz"
    
    if [ ! -f "${config_file}" ]; then
        show_result "Kernel config not available" "FAIL" "CONFIG_IKCONFIG_PROC not enabled"
        return
    fi
    
    # Check required config options
    local required_options=(
        "CONFIG_MULTIKERNEL=y"
        "CONFIG_KEXEC=y"
        "CONFIG_OF=y"
        "CONFIG_OF_OVERLAY=y"
    )
    
    for option in "${required_options[@]}"; do
        local option_name="${option%%=*}"
        local option_value="${option##*=}"
        
        if zcat "${config_file}" 2>/dev/null | grep "^${option}" > /dev/null; then
            show_result "${option_name} = ${option_value}" "PASS"
        else
            show_result "${option_name} not set to ${option_value}" "FAIL" "Required for multikernel"
        fi
    done
    
    # IOMMU: vendor-flexible (Intel OR AMD) - fail only when NEITHER is present
    if zcat "${config_file}" 2>/dev/null | grep "^CONFIG_INTEL_IOMMU=y" > /dev/null; then
        show_result "CONFIG_INTEL_IOMMU = y" "PASS"
    elif zcat "${config_file}" 2>/dev/null | grep "^CONFIG_AMD_IOMMU=y" > /dev/null; then
        show_result "CONFIG_AMD_IOMMU = y" "PASS"
    else
        show_result "IOMMU support (INTEL_IOMMU / AMD_IOMMU)" "FAIL" "Required for device isolation"
    fi
}

# Function to check multikernel modules
check_modules() {
    echo -e "\n${BOLD}Checking multikernel modules...${NC}"
    
    local kernel_version
    kernel_version=$(uname -r)
    local module_path="/lib/modules/${kernel_version}"
    
    if [ -d "${module_path}" ]; then
        show_result "Module directory exists" "PASS"
        
        # Check for multikernel modules
        local mk_modules
        mk_modules=$(find "${module_path}" -name "*multikernel*" -o -name "*kexec*" 2>/dev/null | wc -l)
        
        if [ "${mk_modules}" -gt 0 ]; then
            show_result "Multikernel modules found (${mk_modules})" "PASS"
        else
            show_result "No multikernel modules found" "WARN" "May need to compile multikernel modules"
        fi
    else
        show_result "Module directory not found" "FAIL" "Expected: ${module_path}"
    fi
}

# Function to check multikernel sysfs
check_sysfs() {
    echo -e "\n${BOLD}Checking multikernel sysfs...${NC}"
    
    local sysfs_path="/sys/fs/multikernel"
    
    if [ -d "${sysfs_path}" ]; then
        show_result "Multikernel sysfs mounted" "PASS"
        
        # Check instances directory
        if [ -d "${sysfs_path}/instances" ]; then
            show_result "Instances directory exists" "PASS"
            
            # Count existing instances
            local instance_count
            instance_count=$(ls -1 "${sysfs_path}/instances" 2>/dev/null | wc -l)
            show_result "Existing instances: ${instance_count}" "PASS"
        else
            show_result "Instances directory not found" "WARN" "Will be created on first use"
        fi
    else
        show_result "Multikernel sysfs not mounted" "WARN" "Mount with: mount -t multikernel none /sys/fs/multikernel"
    fi
}

# Function to check IOMMU
check_iommu() {
    echo -e "\n${BOLD}Checking IOMMU configuration...${NC}"
    
    # Check if IOMMU is enabled in kernel
    if dmesg 2>/dev/null | grep -i "iommu\|intel-iommu\|amd-iommu" > /dev/null; then
        show_result "IOMMU detected in kernel messages" "PASS"
    else
        show_result "IOMMU not detected in kernel messages" "WARN" "May need to enable in BIOS/UEFI"
    fi
    
    # Check IOMMU groups
    if [ -d "/sys/kernel/iommu_groups" ]; then
        local group_count
        group_count=$(ls -1 /sys/kernel/iommu_groups 2>/dev/null | wc -l)
        show_result "IOMMU groups available: ${group_count}" "PASS"
    else
        show_result "IOMMU groups not available" "FAIL" "IOMMU may not be enabled"
    fi
}

# Function to check hardware
check_hardware() {
    echo -e "\n${BOLD}Checking hardware requirements...${NC}"
    
    # Check CPU cores
    local cpu_cores
    cpu_cores=$(nproc)
    if [ "${cpu_cores}" -ge 4 ]; then
        show_result "CPU cores: ${cpu_cores} (minimum 4)" "PASS"
    else
        show_result "CPU cores: ${cpu_cores}" "WARN" "Minimum 4 cores recommended"
    fi
    
    # Check RAM
    local total_ram
    total_ram=$(free -g | awk '/^Mem:/{print $2}')
    if [ "${total_ram}" -ge 8 ]; then
        show_result "Total RAM: ${total_ram}GB (minimum 8GB)" "PASS"
    else
        show_result "Total RAM: ${total_ram}GB" "WARN" "Minimum 8GB recommended"
    fi
    
    # Check for multiple disks
    local disk_count
    disk_count=$(lsblk -dno NAME 2>/dev/null | wc -l)
    if [ "${disk_count}" -ge 2 ]; then
        show_result "Disk count: ${disk_count} (minimum 2)" "PASS"
    else
        show_result "Disk count: ${disk_count}" "WARN" "Multiple disks recommended for isolation"
    fi
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  VERIFICATION SUMMARY${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    local total=$((PASSED + FAILED + WARNINGS))
    
    echo -e "  Total checks: ${total}"
    echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
    echo -e "  ${RED}Failed: ${FAILED}${NC}"
    echo -e "  ${YELLOW}Warnings: ${WARNINGS}${NC}"
    echo
    
    if [ "${FAILED}" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✓ MULTIKERNEL INSTALLATION VERIFIED${NC}"
        echo -e "${GREEN}  System is ready for SUSPICIOUS Framework installation${NC}"
    else
        echo -e "${RED}${BOLD}✗ MULTIKERNEL INSTALLATION INCOMPLETE${NC}"
        echo -e "${RED}  Please resolve the failed checks before proceeding${NC}"
    fi
    
    echo
    
    # Recommendations
    if [ "${WARNINGS}" -gt 0 ]; then
        echo -e "${BOLD}Recommendations:${NC}"
        echo "  1. Review warnings above"
        echo "  2. Ensure system meets minimum requirements"
        echo "  3. Consider hardware upgrades if needed"
        echo
    fi
    
    # Next steps
    echo -e "${BOLD}Next Steps:${NC}"
    if [ "${FAILED}" -eq 0 ]; then
        echo "  1. Run: sudo ./check-disks.sh"
        echo "  2. Run: sudo ./partition-disk.sh"
        echo "  3. Run: sudo ./install-child-kernel.sh"
    else
        echo "  1. Resolve failed checks above"
        echo "  2. Re-run this script"
    fi
    
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    check_kernel_version
    check_kernel_config
    check_modules
    check_sysfs
    check_iommu
    check_hardware
    
    show_summary
    
    # Exit code
    if [ "${FAILED}" -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function
main "$@"
