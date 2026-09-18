#!/usr/bin/env bash
# monitor-boot-integrity.sh - Monitor boot integrity
# SUSPICIOUS Framework: Detection Layer
#
# Monitors:
# - Boot partition integrity
# - Kernel image integrity
# - Initramfs integrity
# - GRUB configuration integrity
#
# Usage: sudo ./monitor-boot-integrity.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

CHILD_BOOT="${CHILD_BOOT_DEVICE:-/dev/sdb1}"
CHILD_ROOT="${CHILD_ROOT_DEVICE:-/dev/sdb2}"
MONITOR_DIR="/opt/suspicious/monitoring"
LOG_FILE="/var/log/suspicious-boot-monitor.log"
HASH_FILE="${MONITOR_DIR}/boot-hashes.json"

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         BOOT INTEGRITY MONITOR                                     ║
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

# Function to calculate hash
calculate_hash() {
    local file="$1"
    
    if [ -f "${file}" ]; then
        sha256sum "${file}" | awk '{print $1}'
    else
        echo "FILE_NOT_FOUND"
    fi
}

# Function to save boot hashes
save_boot_hashes() {
    show_step "Saving Boot Hashes" 2
    
    local kernel_hash
    kernel_hash=$(calculate_hash "/boot/vmlinuz-linux-multikernel")
    
    local initramfs_hash
    initramfs_hash=$(calculate_hash "/boot/initramfs-linux-multikernel.img")
    
    local bootloader_hash=""
    local bootloader_type=""
    
    if [ -d /boot/loader/entries ] && command -v bootctl &>/dev/null; then
        bootloader_type="systemd-boot"
        bootloader_hash=$(cat /boot/loader/entries/*.conf 2>/dev/null | sha256sum | cut -d' ' -f1)
    elif [ -f /boot/grub/grub.cfg ]; then
        bootloader_type="grub"
        bootloader_hash=$(calculate_hash "/boot/grub/grub.cfg")
    fi
    
    mkdir -p /var/lib/proj-mk-ultra/watch
    cat /boot/loader/entries/*.conf 2>/dev/null | sha256sum | cut -d' ' -f1 \
        > /var/lib/proj-mk-ultra/watch/boot-hashes.sha256 || true
    cat > "${HASH_FILE}" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "kernel_hash": "${kernel_hash}",
    "initramfs_hash": "${initramfs_hash}",
    "bootloader_type": "${bootloader_type}",
    "bootloader_hash": "${bootloader_hash}"
}
EOF
    
    show_status "OK" "Boot hashes saved"
}

# Function to verify boot integrity
verify_boot_integrity() {
    show_step "Verifying Boot Integrity" 3
    
    # Check if hash file exists
    if [ ! -f "${HASH_FILE}" ]; then
        show_status "WARN" "No previous hash file found, creating baseline"
        save_boot_hashes
        return
    fi
    
    # Load previous hashes
    local prev_kernel_hash
    prev_kernel_hash=$(grep -o '"kernel_hash": "[^"]*"' "${HASH_FILE}" | cut -d'"' -f4)
    
    local prev_initramfs_hash
    prev_initramfs_hash=$(grep -o '"initramfs_hash": "[^"]*"' "${HASH_FILE}" | cut -d'"' -f4)
    
    local prev_bootloader_hash
    prev_bootloader_hash=$(grep -o '"bootloader_hash": "[^"]*"' "${HASH_FILE}" | cut -d'"' -f4)
    
    local curr_kernel_hash
    curr_kernel_hash=$(calculate_hash "/boot/vmlinuz-linux-multikernel")
    
    local curr_initramfs_hash
    curr_initramfs_hash=$(calculate_hash "/boot/initramfs-linux-multikernel.img")
    
    local curr_bootloader_hash="" bootloader_type=""
    if [ -d /boot/loader/entries ] && command -v bootctl &>/dev/null; then
        curr_bootloader_hash=$(cat /boot/loader/entries/*.conf 2>/dev/null | sha256sum | cut -d' ' -f1)
        bootloader_type="systemd-boot"
    elif [ -f /boot/grub/grub.cfg ]; then
        curr_bootloader_hash=$(calculate_hash "/boot/grub/grub.cfg")
        bootloader_type="grub"
    fi

    if [ "${prev_kernel_hash}" = "${curr_kernel_hash}" ]; then
        show_status "OK" "Kernel integrity verified"
    else
        show_status "ERROR" "Kernel integrity check FAILED"
        echo -e "    Expected: ${prev_kernel_hash}"
        echo -e "    Actual: ${curr_kernel_hash}"
    fi

    if [ "${prev_initramfs_hash}" = "${curr_initramfs_hash}" ]; then
        show_status "OK" "Initramfs integrity verified"
    else
        show_status "ERROR" "Initramfs integrity check FAILED"
        echo -e "    Expected: ${prev_initramfs_hash}"
        echo -e "    Actual: ${curr_initramfs_hash}"
    fi

    if [ -n "${prev_bootloader_hash}" ] && [ "${prev_bootloader_hash}" = "${curr_bootloader_hash}" ]; then
        show_status "OK" "Bootloader integrity verified (${bootloader_type})"
    elif [ -n "${prev_bootloader_hash}" ]; then
        show_status "ERROR" "Bootloader integrity check FAILED (${bootloader_type})"
        echo -e "    Expected: ${prev_bootloader_hash}"
        echo -e "    Actual: ${curr_bootloader_hash}"
    else
        show_status "INFO" "No bootloader hash baseline — run once to create baseline"
    fi
}

# Function to monitor boot partition
monitor_boot_partition() {
    show_step "Monitoring Boot Partition" 4
    
    # Check if boot partition is mounted
    if mount | grep -- "${CHILD_BOOT}" > /dev/null; then
        show_status "OK" "Boot partition is mounted"
        
        # Check for modifications
        local mount_point
        mount_point=$(mount | grep "${CHILD_BOOT}" | awk '{print $3}')
        
        # Check for recently modified files
        local modified_files
        modified_files=$(find "${mount_point}" -type f -mmin -60 2>/dev/null | wc -l)
        
        if [ "${modified_files}" -gt 0 ]; then
            show_status "WARN" "Found ${modified_files} recently modified files in boot partition"
        else
            show_status "OK" "No recent modifications to boot partition"
        fi
    else
        show_status "INFO" "Boot partition not mounted"
    fi
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  BOOT INTEGRITY MONITORING COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Monitoring directory: ${MONITOR_DIR}"
    echo -e "  Hash file: ${HASH_FILE}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Files Monitored:${NC}"
    echo -e "  /boot/vmlinuz-linux-multikernel"
    echo -e "  /boot/initramfs-linux-multikernel.img"
    if [ "${bootloader_type:-}" = "systemd-boot" ]; then
        echo -e "  /boot/loader/entries/*.conf"
    elif [ "${bootloader_type:-}" = "grub" ]; then
        echo -e "  /boot/grub/grub.cfg"
    fi
    echo
    
    echo -e "${BOLD}Security Features:${NC}"
    echo -e "  ${GREEN}→ SHA-256 hash verification${NC}"
    echo -e "  ${GREEN}→ Tamper detection${NC}"
    echo -e "  ${GREEN}→ Audit logging${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./monitor-hardware-isolation.sh"
    echo "  2. Run: sudo ./monitor-sysfs-access.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    create_monitoring_directory
    save_boot_hashes
    verify_boot_integrity
    monitor_boot_partition
    
    show_summary
}

# Run main function
main "$@"
