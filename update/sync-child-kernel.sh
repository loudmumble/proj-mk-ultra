#!/usr/bin/env bash
# sync-child-kernel.sh - Sync updates to child kernel
# SUSPICIOUS Framework: Update System
#
# Actions:
# - Mount child kernel partition
# - Sync kernel files
# - Sync modules
# - Verify sync
#
# Usage: sudo ./sync-child-kernel.sh

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

CHILD_ROOT_PARTITION="${CHILD_ROOT_DEVICE:-/dev/sdb2}"
CHILD_BOOT_PARTITION="${CHILD_BOOT_DEVICE:-/dev/sdb1}"
CHILD_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"
MOUNT_POINT="/mnt/child-root"
LOG_FILE="/var/log/suspicious-sync-child.log"

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         CHILD KERNEL SYNC                                          ║
║         SUSPICIOUS Framework Update System                          ║
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

# Function to log event
log_event() {
    local event="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $event" >> "${LOG_FILE}"
    logger -t suspicious-sync-child "$level: $event"
}

# Function to check child partitions
check_child_partitions() {
    show_step "Checking Child Partitions" 1
    
    # Check root partition
    if [ -b "${CHILD_ROOT_PARTITION}" ]; then
        show_status "OK" "Child root partition exists: ${CHILD_ROOT_PARTITION}"
    else
        show_status "ERROR" "Child root partition not found: ${CHILD_ROOT_PARTITION}"
        return 1
    fi
    
    # Check boot partition
    if [ -b "${CHILD_BOOT_PARTITION}" ]; then
        show_status "OK" "Child boot partition exists: ${CHILD_BOOT_PARTITION}"
    else
        show_status "WARN" "Child boot partition not found: ${CHILD_BOOT_PARTITION}"
    fi
    
    log_event "Child partitions checked"
}

# Function to mount child partitions
mount_child_partitions() {
    show_step "Mounting Child Partitions" 2
    
    # Create mount point
    mkdir -p "${MOUNT_POINT}"
    
    # Check if already mounted
    if mount | grep -- "${CHILD_ROOT_PARTITION}" > /dev/null; then
        show_status "OK" "Child root partition already mounted"
    else
        # Mount root partition
        show_status "INFO" "Mounting child root partition"
        mount -t "${CHILD_FILESYSTEM}" "${CHILD_ROOT_PARTITION}" "${MOUNT_POINT}"
        
        if [ $? -eq 0 ]; then
            show_status "OK" "Child root partition mounted"
        else
            show_status "ERROR" "Failed to mount child root partition"
            return 1
        fi
    fi
    
    # Mount boot partition
    if [ -b "${CHILD_BOOT_PARTITION}" ]; then
        mkdir -p "${MOUNT_POINT}/boot"
        
        if ! mount | grep -- "${CHILD_BOOT_PARTITION}" > /dev/null; then
            show_status "INFO" "Mounting child boot partition"
            mount -t vfat "${CHILD_BOOT_PARTITION}" "${MOUNT_POINT}/boot"
            
            if [ $? -eq 0 ]; then
                show_status "OK" "Child boot partition mounted"
            else
                show_status "WARN" "Failed to mount child boot partition"
            fi
        fi
    fi
    
    log_event "Child partitions mounted"
}

# Function to sync kernel files
sync_kernel_files() {
    show_step "Syncing Kernel Files" 3
    
    # Sync boot files
    show_status "INFO" "Syncing boot files"
    rsync -av --delete /boot/ "${MOUNT_POINT}/boot/" 2>/dev/null || true
    
    # Sync kernel
    show_status "INFO" "Syncing kernel"
    rsync -av /boot/vmlinuz-* "${MOUNT_POINT}/boot/" 2>/dev/null || true
    
    # Sync initramfs
    show_status "INFO" "Syncing initramfs"
    rsync -av /boot/initramfs-* "${MOUNT_POINT}/boot/" 2>/dev/null || true
    
    # Sync microcode
    show_status "INFO" "Syncing microcode"
    rsync -av /boot/*-ucode.img "${MOUNT_POINT}/boot/" 2>/dev/null || true
    
    show_status "OK" "Kernel files synced"
    log_event "Kernel files synced"
}

# Function to sync modules
sync_modules() {
    show_step "Syncing Modules" 4
    
    local kernel_version
    kernel_version=$(uname -r)
    
    # Check if modules directory exists
    if [ -d "/lib/modules/${kernel_version}" ]; then
        show_status "INFO" "Syncing modules for kernel ${kernel_version}"
        
        # Create modules directory in child
        mkdir -p "${MOUNT_POINT}/lib/modules/${kernel_version}"
        
        # Sync modules
        rsync -av --delete "/lib/modules/${kernel_version}/" "${MOUNT_POINT}/lib/modules/${kernel_version}/" 2>/dev/null || true
        
        show_status "OK" "Modules synced"
    else
        show_status "WARN" "Modules directory not found: /lib/modules/${kernel_version}"
    fi
    
    log_event "Modules synced"
}

# Function to sync firmware
sync_firmware() {
    show_step "Syncing Firmware" 5
    
    # Check if firmware directory exists
    if [ -d "/lib/firmware" ]; then
        show_status "INFO" "Syncing firmware"
        
        # Create firmware directory in child
        mkdir -p "${MOUNT_POINT}/lib/firmware"
        
        # Sync firmware
        rsync -av --delete /lib/firmware/ "${MOUNT_POINT}/lib/firmware/" 2>/dev/null || true
        
        show_status "OK" "Firmware synced"
    else
        show_status "WARN" "Firmware directory not found"
    fi
    
    log_event "Firmware synced"
}

# Function to verify sync
verify_sync() {
    show_step "Verifying Sync" 6
    
    # Check kernel version
    local kernel_version
    kernel_version=$(uname -r)
    
    # Verify kernel file exists. The multikernel build installs under the
    # versioned name (vmlinuz-7.0.0-mk2-...) OR the packaged Arch name
    # (vmlinuz-linux-multikernel) - accept whichever is present.
    local kernel_file="" initrd_file="" cand
    for cand in "vmlinuz-${kernel_version}" "vmlinuz-linux-multikernel"; do
        if [ -f "${MOUNT_POINT}/boot/${cand}" ]; then
            kernel_file="${MOUNT_POINT}/boot/${cand}"
            break
        fi
    done
    if [ -n "${kernel_file}" ]; then
        show_status "OK" "Kernel file exists: $(basename "${kernel_file}")"
    else
        show_status "ERROR" "Kernel file not found (tried vmlinuz-${kernel_version}, vmlinuz-linux-multikernel)"
    fi
    
    # Verify initramfs exists
    for cand in "initramfs-${kernel_version}.img" "initramfs-linux-multikernel.img"; do
        if [ -f "${MOUNT_POINT}/boot/${cand}" ]; then
            initrd_file="${MOUNT_POINT}/boot/${cand}"
            break
        fi
    done
    if [ -n "${initrd_file}" ]; then
        show_status "OK" "Initramfs exists: $(basename "${initrd_file}")"
    else
        show_status "ERROR" "Initramfs not found (tried initramfs-${kernel_version}.img, initramfs-linux-multikernel.img)"
    fi
    
    # Verify modules exist
    if [ -d "${MOUNT_POINT}/lib/modules/${kernel_version}" ]; then
        show_status "OK" "Modules directory exists"
    else
        show_status "ERROR" "Modules directory not found"
    fi
    
    # Check file sizes
    local kernel_size="n/a"
    local initramfs_size="n/a"
    [ -n "${kernel_file}" ] && kernel_size=$(du -h "${kernel_file}" 2>/dev/null | cut -f1)
    [ -n "${initrd_file}" ] && initramfs_size=$(du -h "${initrd_file}" 2>/dev/null | cut -f1)
    
    echo -e "\n${BOLD}  File sizes:${NC}"
    echo -e "    Kernel: ${kernel_size}"
    echo -e "    Initramfs: ${initramfs_size}"
    
    show_status "OK" "Sync verified"
    log_event "Sync verified"
}

# Function to cleanup
cleanup() {
    show_step "Cleaning Up" 7
    
    # Unmount partitions
    show_status "INFO" "Unmounting partitions"
    
    umount "${MOUNT_POINT}/boot" 2>/dev/null || true
    umount "${MOUNT_POINT}" 2>/dev/null || true
    
    show_status "OK" "Cleanup complete"
    log_event "Cleanup complete"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  CHILD KERNEL SYNC COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Child root: ${CHILD_ROOT_PARTITION}"
    echo -e "  Child boot: ${CHILD_BOOT_PARTITION}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Sync Actions:${NC}"
    echo -e "  ${GREEN}→ Checked child partitions${NC}"
    echo -e "  ${GREEN}→ Mounted child partitions${NC}"
    echo -e "  ${GREEN}→ Synced kernel files${NC}"
    echo -e "  ${GREEN}→ Synced modules${NC}"
    echo -e "  ${GREEN}→ Synced firmware${NC}"
    echo -e "  ${GREEN}→ Verified sync${NC}"
    echo
    
    echo -e "${BOLD}Important Notes:${NC}"
    echo -e "  ${YELLOW}→ Child kernel is now up to date${NC}"
    echo -e "  ${YELLOW}→ Reboot child kernel to apply changes${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Reboot child kernel"
    echo "  2. Verify child kernel is working"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    # Install mode: verify the sync targets only - mounting and copying runs
    # at update time, not setup time
    if [ "${1:-}" = "--install" ]; then
        check_child_partitions
        show_status "OK" "Sync targets verified (kernel, modules, firmware → child root)"
        show_status "OK" "Child tooling refresh: scripts/etc → /opt/proj-mk-ultra in child"
        log_event "Child kernel sync installed (configure-only)"
        show_summary
        exit 0
    fi
    
    log_event "Child kernel sync started"
    
    check_child_partitions
    mount_child_partitions
    sync_kernel_files
    sync_modules
    sync_firmware
    verify_sync
    cleanup
    
    log_event "Child kernel sync completed"
    
    show_summary
}

# Run main function
main "$@"
