#!/usr/bin/env bash
# verify-iommu.sh - Verify IOMMU configuration for child kernel
# SUSPICIOUS Framework: Prevention Layer
#
# Verifies:
# - IOMMU is enabled in BIOS/UEFI
# - IOMMU is enabled in kernel
# - IOMMU groups are properly configured
# - PCI devices are properly isolated
#
# Usage: sudo ./verify-iommu.sh

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
║         IOMMU VERIFICATION                                        ║
║         SUSPICIOUS Framework Prevention Layer                       ║
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

# Function to check IOMMU in kernel
check_iommu_kernel() {
    echo -e "\n${BOLD}Checking IOMMU in kernel...${NC}"
    
    # Check kernel command line
    local cmdline
    cmdline=$(cat /proc/cmdline)
    
    if echo "${cmdline}" | grep -i "intel_iommu=on\|amd_iommu=on\|iommu=pt" > /dev/null; then
        show_result "IOMMU enabled in kernel command line" "PASS"
    else
        show_result "IOMMU not enabled in kernel command line" "FAIL" "Add intel_iommu=on or amd_iommu=on to systemd-boot or GRUB"
    fi
    
    # Kernel messages: advisory only. The structural evidence (IOMMU groups
    # with devices) is the gate - kernel message text varies across versions
    # and its absence proves nothing when the hardware translation is live.
    if dmesg 2>/dev/null | grep -i "iommu\|intel-iommu\|amd-iommu" > /dev/null; then
        show_result "IOMMU detected in kernel messages" "PASS"
    elif [ -d "/sys/kernel/iommu_groups" ] && \
         find /sys/kernel/iommu_groups -name devices -type d 2>/dev/null | \
         xargs -I{} sh -c 'ls "{}" 2>/dev/null | head -1' | grep -- . > /dev/null; then
        show_result "IOMMU active (groups populated; message text not matched)" "PASS"
    else
        show_result "IOMMU not detected in kernel messages" "WARN" "Groups also absent - verify BIOS/VT-d and intel_iommu=on"
    fi
    
    # Check /sys/kernel/iommu_groups
    if [ -d "/sys/kernel/iommu_groups" ]; then
        show_result "IOMMU groups directory exists" "PASS"
    else
        show_result "IOMMU groups directory not found" "FAIL"
    fi
}

# Function to check IOMMU groups
check_iommu_groups() {
    echo -e "\n${BOLD}Checking IOMMU groups...${NC}"
    
    if [ ! -d "/sys/kernel/iommu_groups" ]; then
        show_result "IOMMU groups not available" "FAIL"
        return
    fi
    
    local group_count
    group_count=$(ls -1 /sys/kernel/iommu_groups 2>/dev/null | wc -l)
    
    if [ "${group_count}" -gt 0 ]; then
        show_result "IOMMU groups found: ${group_count}" "PASS"
    else
        show_result "No IOMMU groups found" "FAIL"
    fi
    
    # Check for devices in groups
    local devices_in_groups=0
    for group in /sys/kernel/iommu_groups/*/devices/*; do
        if [ -e "${group}" ]; then
            devices_in_groups=$((devices_in_groups + 1))
        fi
    done
    
    if [ "${devices_in_groups}" -gt 0 ]; then
        show_result "Devices in IOMMU groups: ${devices_in_groups}" "PASS"
    else
        show_result "No devices in IOMMU groups" "WARN"
    fi
}

# Function to check PCI devices
check_pci_devices() {
    echo -e "\n${BOLD}Checking PCI devices...${NC}"
    
    # List PCI devices
    echo -e "${BOLD}  PCI Devices:${NC}"
    lspci 2>/dev/null | head -20 | while read line; do
        echo -e "    ${line}"
    done
    
    # Check for GPU
    if lspci 2>/dev/null | grep -i "vga\|3d\|display" > /dev/null; then
        show_result "GPU detected" "PASS"
        
        # Check IOMMU group for GPU
        local gpu_line
        gpu_line=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | head -1)
        
        if [ -n "${gpu_line}" ]; then
            local gpu_address
            gpu_address=$(echo "${gpu_line}" | awk '{print $1}')
            
            # Find IOMMU group for this device
            for group in /sys/kernel/iommu_groups/*/devices/*; do
                if [ -e "${group}" ] && [ "$(basename "${group}")" = "${gpu_address}" ]; then
                    local group_num
                    group_num=$(echo "${group}" | cut -d'/' -f5)
                    show_result "GPU IOMMU group: ${group_num}" "PASS"
                    break
                fi
            done
        fi
    else
        show_result "No GPU detected" "WARN"
    fi
    
    # Check for network adapter
    if lspci 2>/dev/null | grep -i "ethernet\|network\|wifi" > /dev/null; then
        show_result "Network adapter detected" "PASS"
    else
        show_result "No network adapter detected" "WARN"
    fi
}

# Function to check DMA protection
check_dma_protection() {
    echo -e "\n${BOLD}Checking DMA protection...${NC}"
    
    # Check for DMAR (Intel) - advisory; group evidence above is the gate
    if dmesg 2>/dev/null | grep -i "DMAR\|Intel.*IOMMU" > /dev/null; then
        show_result "Intel DMA protection detected" "PASS"
    fi
    
    # Check for AMD IOMMU
    if dmesg 2>/dev/null | grep -i "AMD.*IOMMU\|IOMMU.*AMD" > /dev/null; then
        show_result "AMD DMA protection detected" "PASS"
    fi
    
    # Check for interrupt remapping
    if dmesg 2>/dev/null | grep -i "interrupt.*remapping\|IR" > /dev/null; then
        show_result "Interrupt remapping enabled" "PASS"
    else
        show_result "Interrupt remapping not detected" "WARN" "May not be enabled in BIOS"
    fi
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  IOMMU VERIFICATION SUMMARY${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    local total=$((PASSED + FAILED + WARNINGS))
    
    echo -e "  Total checks: ${total}"
    echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
    echo -e "  ${RED}Failed: ${FAILED}${NC}"
    echo -e "  ${YELLOW}Warnings: ${WARNINGS}${NC}"
    echo
    
    if [ "${FAILED}" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✓ IOMMU VERIFICATION PASSED${NC}"
        echo -e "${GREEN}  IOMMU is properly configured for child kernel isolation${NC}"
    else
        echo -e "${RED}${BOLD}✗ IOMMU VERIFICATION FAILED${NC}"
        echo -e "${RED}  IOMMU must be enabled for proper isolation${NC}"
    fi
    
    echo
    
    # Recommendations
    echo -e "${BOLD}Recommendations:${NC}"
    if [ "${FAILED}" -gt 0 ]; then
        echo "  1. Enable IOMMU in BIOS/UEFI"
        echo "  2. Add kernel parameters: intel_iommu=on iommu=pt"
        echo "  3. Reboot and re-run this script"
    else
        echo "  1. IOMMU is properly configured"
        echo "  2. Proceed with child kernel installation"
    fi
    
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    check_iommu_kernel
    check_iommu_groups
    check_pci_devices
    check_dma_protection
    
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
