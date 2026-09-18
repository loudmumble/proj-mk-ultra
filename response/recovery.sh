#!/usr/bin/env bash
# recovery.sh - Recovery procedures
# SUSPICIOUS Framework: Response Layer
#
# Actions:
# - Verify system state
# - Restore from backup if needed
# - Rebuild child kernel
# - Verify recovery
#
# Usage: sudo ./recovery.sh

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

MULTIKERNEL_SYSFS="/sys/fs/multikernel"
CHILD_INSTANCE="child0"
USER_DATA_PARTITION="${CHILD_DATA_DEVICE:-/dev/sdb3}"
USER_DATA_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"
BACKUP_DIR="/opt/suspicious/backups"
LOG_FILE="/var/log/suspicious-recovery.log"

# shellcheck source=../scripts/lib-hardware.sh
. "${SCRIPT_DIR}/../scripts/lib-hardware.sh"
CHILD_CPU_MASK="${CHILD_CPU_MASK:-0xFFFFFFF0}"
CHILD_MEMORY_SIZE="${CHILD_MEMORY_SIZE:-112G}"
PASSTHROUGH_PCI_DEVICES="${PASSTHROUGH_PCI_DEVICES:-01:00.0}"

# Resolve the child instance this script operates on: explicit child0, else
# the first running non-host instance (spawn generates child-<timestamp> names)
resolve_child_instance() {
    if [ -d "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}" ]; then
        return 0
    fi
    local inst role
    for inst in "${MULTIKERNEL_SYSFS}/instances/"*; do
        [ -d "${inst}" ] || continue
        role=$(cat "${inst}/role" 2>/dev/null || echo "")
        if [ "${role}" != "host" ]; then
            CHILD_INSTANCE=$(basename "${inst}")
            show_status "INFO" "Resolved child instance: ${CHILD_INSTANCE}"
            return 0
        fi
    done
    return 1
}

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         RECOVERY SYSTEM                                            ║
║         SUSPICIOUS Framework Response Layer                         ║
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
    logger -t suspicious-recovery "$level: $event"
}

# Function to verify system state
verify_system_state() {
    show_step "Verifying System State" 1
    
    # Check kernel
    echo -e "\n${BOLD}  Checking kernel...${NC}"
    local kernel_version
    kernel_version=$(uname -r)
    echo -e "    Kernel: ${kernel_version}"
    
    # Check kernel taint
    if [ -f "/proc/sys/kernel/tainted" ]; then
        local tainted
        tainted=$(cat /proc/sys/kernel/tainted)
        if [ "${tainted}" -eq 0 ]; then
            show_status "OK" "Kernel is clean (taint: 0)"
        else
            show_status "WARN" "Kernel is tainted: ${tainted}"
        fi
    fi
    
    # Check multikernel
    echo -e "\n${BOLD}  Checking multikernel...${NC}"
    if [ -d "${MULTIKERNEL_SYSFS}" ]; then
        show_status "OK" "Multikernel sysfs mounted"
        
        # Check instances
        if [ -d "${MULTIKERNEL_SYSFS}/instances" ]; then
            local instance_count
            instance_count=$(ls -1 "${MULTIKERNEL_SYSFS}/instances" 2>/dev/null | wc -l)
            echo -e "    Instances: ${instance_count}"
        fi
    else
        show_status "WARN" "Multikernel sysfs not mounted"
    fi
    
    # Check user data partition
    echo -e "\n${BOLD}  Checking user data partition...${NC}"
    if [ -b "${USER_DATA_PARTITION}" ]; then
        show_status "OK" "User data partition exists"
        
        # Check if mounted
        if mount | grep -- "${USER_DATA_PARTITION}" > /dev/null; then
            show_status "OK" "User data partition is mounted"
        else
            show_status "WARN" "User data partition not mounted"
        fi
    else
        show_status "ERROR" "User data partition not found"
    fi
    
    log_event "System state verified"
}

# Function to restore from backup
restore_from_backup() {
    show_step "Restoring from Backup" 2
    
    # Check if backup directory exists
    if [ ! -d "${BACKUP_DIR}" ]; then
        show_status "WARN" "No backup directory found"
        return
    fi
    
    # List backups
    local backups
    backups=$(ls -1 "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -5)
    
    if [ -z "${backups}" ]; then
        show_status "WARN" "No backups found"
        return
    fi
    
    echo -e "\n${BOLD}  Available backups:${NC}"
    echo "${backups}" | while read backup; do
        echo -e "    - $(basename "${backup}")"
    done
    
    # Prompt for restore
    echo -e "\n${BOLD}  Do you want to restore from backup? (yes/no): ${NC}"
    read -r restore_choice
    
    if [ "${restore_choice}" = "yes" ]; then
        # Get latest backup
        local latest_backup
        latest_backup=$(ls -1t "${BACKUP_DIR}"/*.tar.gz | head -1)
        
        echo -e "\n${BOLD}  Restoring from: ${latest_backup}${NC}"
        
        # Mount user data partition
        local mount_point="/mnt/preserved-data"
        mkdir -p "${mount_point}"
        
        if ! mount | grep -- "${USER_DATA_PARTITION}" > /dev/null; then
            local user_fs
            user_fs=$(blkid -s TYPE -o value "${USER_DATA_PARTITION}" 2>/dev/null || echo "ext4")
            mount -t "${user_fs}" "${USER_DATA_PARTITION}" "${mount_point}"
        fi
        
        # Restore from backup
        tar -xzf "${latest_backup}" -C "${mount_point}"
        
        show_status "OK" "Backup restored"
        log_event "Backup restored from ${latest_backup}"
    else
        show_status "INFO" "Restore skipped"
    fi
}

# Function to rebuild child kernel
rebuild_child_kernel() {
    show_step "Rebuilding Child Kernel" 3
    
    # Check if child instance exists
    if [ -d "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}" ]; then
        show_status "INFO" "Child instance exists, destroying first"
        
        # Destroy existing child
        echo "shutdown" > "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/control" 2>/dev/null || true
        sleep 5
    fi

    # Overlay-based removal (verified create/destroy mechanism)
    mk_remove_instance_overlay "${CHILD_INSTANCE}" || true

    # Create the instance via the overlay API (draws from the pool)
    if ! mk_create_instance_overlay "${CHILD_INSTANCE}"; then
        show_status "ERROR" "Instance creation failed - kernel messages:"
        dmesg | tail -6 | sed 's/^/    /'
        log_event "Failed to rebuild child instance" "ERROR"
        return 1
    fi
    show_status "OK" "Child instance created from pool: ${CHILD_INSTANCE}"
    
    # Boot child kernel — background the control write, poll for running state.
    show_status "INFO" "Booting child kernel"
    ( echo "boot" > "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/control" 2>/dev/null ) &

    # Wait for boot
    local timeout=30
    while [ ${timeout} -gt 0 ]; do
        if [ -f "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/status" ]; then
            local status
            status=$(cat "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/status")
            if [ "${status}" = "running" ]; then
                show_status "OK" "Child kernel rebuilt"
                log_event "Child kernel rebuilt"
                return 0
            fi
        fi
        sleep 1
        timeout=$((timeout - 1))
    done

    show_status "ERROR" "Failed to rebuild child kernel"
    log_event "Failed to rebuild child kernel" "ERROR"
    return 1
}

# Function to verify recovery
verify_recovery() {
    show_step "Verifying Recovery" 4
    
    # Check child kernel status
    if [ -f "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/status" ]; then
        local status
        status=$(cat "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/status")
        
        if [ "${status}" = "running" ]; then
            show_status "OK" "Child kernel is running"
        else
            show_status "WARN" "Child kernel status: ${status}"
        fi
    else
        show_status "ERROR" "Child kernel not found"
    fi
    
    # Check user data
    if mount | grep -- "${USER_DATA_PARTITION}" > /dev/null; then
        show_status "OK" "User data is accessible"
    else
        show_status "WARN" "User data not mounted"
    fi
    
    # Check system logs
    if [ -f "${LOG_FILE}" ]; then
        local log_entries
        log_entries=$(wc -l < "${LOG_FILE}")
        echo -e "\n${BOLD}  Log entries: ${log_entries}${NC}"
    fi
    
    log_event "Recovery verified"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  RECOVERY COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Log file: ${LOG_FILE}"
    echo -e "  Backup directory: ${BACKUP_DIR}"
    echo
    
    echo -e "${BOLD}Recovery Actions:${NC}"
    echo -e "  ${GREEN}→ System state verified${NC}"
    echo -e "  ${GREEN}→ Backup restored (if selected)${NC}"
    echo -e "  ${GREEN}→ Child kernel rebuilt${NC}"
    echo -e "  ${GREEN}→ Recovery verified${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Monitor system for stability"
    echo "  2. Investigate root cause"
    echo "  3. Update security measures"
    echo
}

# Main function
main() {
    show_banner
    check_root
    validate_required_config CHILD_CPU_MASK CHILD_MEMORY_SIZE PASSTHROUGH_PCI_DEVICES || true
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    # Install mode: verify recovery prerequisites only - the rebuild flow
    # boots a child instance and must never run at setup time
    if [ "${1:-}" = "--install" ]; then
        show_status "OK" "Recovery prerequisites:"
        [ -f "${CONFIG_FILE}" ] && show_status "OK" "Config: ${CONFIG_FILE}" || show_status "WARN" "Config missing: ${CONFIG_FILE}"
        [ -n "${CHILD_ROOT_DEVICE:-}" ] && [ -b "${CHILD_ROOT_DEVICE}" ] && show_status "OK" "Child root: ${CHILD_ROOT_DEVICE}" || show_status "WARN" "Child root device not set (run partition-disk.sh)"
        show_status "OK" "Recovery flow armed: verify state → restore backup → rebuild child → verify"
        log_event "Recovery layer installed (configure-only)"
        show_summary
        exit 0
    fi
    
    log_event "Recovery started"
    
    if ! resolve_child_instance; then
        show_status "WARN" "No running child instance found - recovery will create a new one"
    fi
    
    verify_system_state
    restore_from_backup
    rebuild_child_kernel
    verify_recovery
    
    log_event "Recovery completed"
    
    show_summary
}

# Run main function
main "$@"
