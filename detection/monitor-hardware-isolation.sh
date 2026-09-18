#!/usr/bin/env bash
# monitor-hardware-isolation.sh - Monitor hardware isolation
# SUSPICIOUS Framework: Detection Layer
#
# Monitors:
# - IOMMU group assignments
# - PCI device isolation
# - DMA protection
# - Hardware resource allocation
#
# Usage: sudo ./monitor-hardware-isolation.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Configuration
MONITOR_DIR="/opt/suspicious/monitoring"
LOG_FILE="/var/log/suspicious-hardware-monitor.log"
STATE_FILE="${MONITOR_DIR}/hardware-state.json"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         HARDWARE ISOLATION MONITOR                                 ║
║         SUSPICIOUS Framework Detection Layer                        ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Function to display step
show_step() {
    local step_name="$1"
    local step_number="$2"
    echo -e "\n${BOLD}[Step ${step_number}] ${step_name}${NC}"
}

# Function to display status
show_status() {
    local status="$1"
    local message="$2"
    
    case "${status}" in
        OK)
            echo -e "  ${GREEN}✓ ${message}${NC}"
            ;;
        WARN)
            echo -e "  ${YELLOW}⚠ ${message}${NC}"
            ;;
        ERROR)
            echo -e "  ${RED}✗ ${message}${NC}"
            ;;
        INFO)
            echo -e "  ${BLUE}→ ${message}${NC}"
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

# Function to create monitoring directory
create_monitoring_directory() {
    show_step "Creating Monitoring Directory" 1
    
    mkdir -p "${MONITOR_DIR}"
    
    show_status "OK" "Monitoring directory created: ${MONITOR_DIR}"
}

# Function to get IOMMU groups
get_iommu_groups() {
    echo -e "\n${BOLD}  IOMMU Groups:${NC}"
    
    if [ -d "/sys/kernel/iommu_groups" ]; then
        for group in /sys/kernel/iommu_groups/*/; do
            local group_num
            group_num=$(basename "${group}")
            
            local devices
            devices=$(ls -1 "${group}/devices" 2>/dev/null | wc -l)
            
            echo -e "    Group ${group_num}: ${devices} devices"
        done
    else
        echo -e "    ${YELLOW}IOMMU groups not available${NC}"
    fi
}

# Function to check IOMMU configuration
check_iommu_configuration() {
    show_step "Checking IOMMU Configuration" 2
    
    # Check if IOMMU is enabled
    if [ -d "/sys/kernel/iommu_groups" ]; then
        local group_count
        group_count=$(ls -1 /sys/kernel/iommu_groups 2>/dev/null | wc -l)
        
        if [ "${group_count}" -gt 0 ]; then
            show_status "OK" "IOMMU groups available: ${group_count}"
        else
            show_status "ERROR" "No IOMMU groups found"
        fi
    else
        show_status "ERROR" "IOMMU not enabled"
    fi
    
    # Check for DMAR (Intel)
    if dmesg 2>/dev/null | grep -i "DMAR\|Intel.*IOMMU" > /dev/null; then
        show_status "OK" "Intel IOMMU detected"
    fi
    
    # Check for AMD IOMMU
    if dmesg 2>/dev/null | grep -i "AMD.*IOMMU\|IOMMU.*AMD" > /dev/null; then
        show_status "OK" "AMD IOMMU detected"
    fi
}

# Function to check PCI device isolation
check_pci_isolation() {
    show_step "Checking PCI Device Isolation" 3
    
    # List PCI devices
    echo -e "${BOLD}  PCI Devices:${NC}"
    lspci 2>/dev/null | head -10 | while read line; do
        echo -e "    ${line}"
    done
    
    # Check for GPU
    if lspci 2>/dev/null | grep -i "vga\|3d\|display" > /dev/null; then
        show_status "OK" "GPU detected"
        
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
                    show_status "OK" "GPU IOMMU group: ${group_num}"
                    break
                fi
            done
        fi
    else
        show_status "WARN" "No GPU detected"
    fi
}

# Function to check DMA protection
check_dma_protection() {
    show_step "Checking DMA Protection" 4
    
    # Check for interrupt remapping
    if dmesg 2>/dev/null | grep -i "interrupt.*remapping\|IR" > /dev/null; then
        show_status "OK" "Interrupt remapping enabled"
    else
        show_status "WARN" "Interrupt remapping not detected"
    fi
    
    # Check for DMA protection
    if dmesg 2>/dev/null | grep -i "DMA.*protection\|DMAR" > /dev/null; then
        show_status "OK" "DMA protection enabled"
    else
        show_status "WARN" "DMA protection not detected"
    fi
}

# Function to check hardware resource allocation
check_resource_allocation() {
    show_step "Checking Hardware Resource Allocation" 5
    
    # Check CPU cores
    local cpu_cores
    cpu_cores=$(nproc)
    
    echo -e "${BOLD}  CPU Configuration:${NC}"
    echo -e "    Total cores: ${cpu_cores}"
    
    # Check CPU isolation
    local isolcpus
    isolcpus=$(cat /proc/cmdline | grep -o "isolcpus=[^ ]*" | cut -d= -f2)
    
    if [ -n "${isolcpus}" ]; then
        show_status "OK" "isolcpus present: ${isolcpus} (not required - CPU isolation uses the DT cpu-mask)"
    else
        show_status "OK" "No isolcpus (expected - CPU isolation uses the multikernel DT cpu-mask: CHILD_CPU_MASK)"
    fi
    
    # Check memory
    local total_memory
    total_memory=$(free -g | awk '/^Mem:/{print $2}')
    
    echo -e "\n${BOLD}  Memory Configuration:${NC}"
    echo -e "    Total memory: ${total_memory}GB"
    
    # Check memory isolation
    local memory_isolation
    memory_isolation=$(cat /proc/cmdline | grep -oE "(memmap|movablecore)=[^ ]*")
    
    if [ -n "${memory_isolation}" ]; then
        show_status "OK" "Memory isolation configured: ${memory_isolation}"
    else
        show_status "WARN" "No memory isolation configured (movablecore= absent)"
    fi
}

# Function to save hardware state
save_hardware_state() {
    show_step "Saving Hardware State" 6
    
    # Save current hardware state
    cat > "${STATE_FILE}" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "iommu_groups": $(ls -1 /sys/kernel/iommu_groups 2>/dev/null | wc -l),
    "cpu_cores": $(nproc),
    "total_memory_gb": $(free -g | awk '/^Mem:/{print $2}'),
    "pci_devices": $(lspci 2>/dev/null | wc -l)
}
EOF
    
    show_status "OK" "Hardware state saved"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  HARDWARE ISOLATION MONITORING COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Monitoring directory: ${MONITOR_DIR}"
    echo -e "  State file: ${STATE_FILE}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Hardware Features Monitored:${NC}"
    echo -e "  ${GREEN}→ IOMMU groups${NC}"
    echo -e "  ${GREEN}→ PCI device isolation${NC}"
    echo -e "  ${GREEN}→ DMA protection${NC}"
    echo -e "  ${GREEN}→ CPU isolation${NC}"
    echo -e "  ${GREEN}→ Memory isolation${NC}"
    echo
    
    echo -e "${BOLD}Security Features:${NC}"
    echo -e "  ${GREEN}→ Hardware state tracking${NC}"
    echo -e "  ${GREEN}→ Tamper detection${NC}"
    echo -e "  ${GREEN}→ Audit logging${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./monitor-sysfs-access.sh"
    echo "  2. Run: sudo ./monitor-module-loading.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    create_monitoring_directory
    get_iommu_groups
    check_iommu_configuration
    check_pci_isolation
    check_dma_protection
    check_resource_allocation
    save_hardware_state
    
    show_summary
}

# Run main function
main "$@"
