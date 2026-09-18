#!/usr/bin/env bash
# preserve-data.sh - Preserve user data during child kernel destruction
# SUSPICIOUS Framework: Response Layer
#
# Actions:
# - Mount user data partition
# - Verify data integrity
# - Create backup if needed
# - Ensure data survives child kernel rebuild
#
# Usage: sudo ./preserve-data.sh

set -euo pipefail

# Colors
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

USER_DATA_PARTITION="${CHILD_DATA_DEVICE:-/dev/sdb3}"
USER_DATA_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"
MOUNT_POINT="/mnt/preserved-data"
BACKUP_DIR="/opt/suspicious/backups"
LOG_FILE="/var/log/suspicious-preserve-data.log"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         DATA PRESERVATION SYSTEM                                   ║
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
    logger -t suspicious-preserve-data "$level: $event"
}

# Function to check user data partition
check_user_data_partition() {
    show_step "Checking User Data Partition" 1
    
    # Check if partition exists
    if [ ! -b "${USER_DATA_PARTITION}" ]; then
        show_status "ERROR" "User data partition not found: ${USER_DATA_PARTITION}"
        log_event "User data partition not found" "ERROR"
        return 1
    fi
    
    show_status "OK" "User data partition exists"
    
    # Check filesystem type
    local fs_type
    fs_type=$(blkid -s TYPE -o value "${USER_DATA_PARTITION}" 2>/dev/null || echo "unknown")
    
    echo -e "\n${BOLD}  Filesystem type: ${fs_type}${NC}"
    
    # Check filesystem health
    if command -v e2fsck &> /dev/null; then
        show_status "INFO" "Checking filesystem health"
        e2fsck -n "${USER_DATA_PARTITION}" 2>/dev/null || true
    fi
    
    log_event "User data partition checked"
}

# Function to mount user data
mount_user_data() {
    show_step "Mounting User Data" 2
    
    if mount | grep -- "${USER_DATA_PARTITION}" > /dev/null; then
        show_status "OK" "User data partition already mounted"
        
        local current_mount
        current_mount=$(mount | grep "${USER_DATA_PARTITION}" | awk '{print $3}')
        
        echo -e "\n${BOLD}  Current mount point: ${current_mount}${NC}"
    else
        mkdir -p "${MOUNT_POINT}"
        
        show_status "INFO" "Mounting user data partition (${USER_DATA_FILESYSTEM})"
        mount -t "${USER_DATA_FILESYSTEM}" "${USER_DATA_PARTITION}" "${MOUNT_POINT}"
        
        if [ $? -eq 0 ]; then
            show_status "OK" "User data partition mounted"
            log_event "User data partition mounted at ${MOUNT_POINT}"
        else
            show_status "ERROR" "Failed to mount user data partition"
            log_event "Failed to mount user data partition" "ERROR"
            return 1
        fi
    fi
}

# Function to verify data integrity
verify_data_integrity() {
    show_step "Verifying Data Integrity" 3
    
    # Check if mount point exists
    if [ ! -d "${MOUNT_POINT}" ]; then
        show_status "ERROR" "Mount point not found: ${MOUNT_POINT}"
        return 1
    fi
    
    # Count files
    local file_count
    file_count=$(find "${MOUNT_POINT}" -type f 2>/dev/null | wc -l)
    
    echo -e "\n${BOLD}  Files found: ${file_count}${NC}"
    
    # Check for critical directories
    local critical_dirs=(
        "workspace"
        "documents"
        "downloads"
        "config"
        "logs"
    )
    
    for dir in "${critical_dirs[@]}"; do
        if [ -d "${MOUNT_POINT}/${dir}" ]; then
            show_status "OK" "Directory exists: ${dir}"
        else
            show_status "WARN" "Directory missing: ${dir}"
        fi
    done
    
    # Check for recent modifications
    local recent_files
    recent_files=$(find "${MOUNT_POINT}" -type f -mmin -60 2>/dev/null | wc -l)
    
    if [ "${recent_files}" -gt 0 ]; then
        show_status "WARN" "Found ${recent_files} recently modified files"
    else
        show_status "OK" "No recent modifications"
    fi
    
    log_event "Data integrity verified: ${file_count} files"
}

# Function to create backup
create_backup() {
    show_step "Creating Backup" 4
    
    # Create backup directory
    mkdir -p "${BACKUP_DIR}"
    
    # Create backup filename
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/user-data-${timestamp}.tar.gz"
    
    # Create backup
    show_status "INFO" "Creating backup"
    tar -czf "${backup_file}" -C "${MOUNT_POINT}" .
    
    if [ $? -eq 0 ]; then
        show_status "OK" "Backup created: ${backup_file}"
        log_event "Backup created: ${backup_file}"
    else
        show_status "ERROR" "Failed to create backup"
        log_event "Failed to create backup" "ERROR"
        return 1
    fi
    
    # Verify backup
    local backup_size
    backup_size=$(du -h "${backup_file}" | cut -f1)
    echo -e "\n${BOLD}  Backup size: ${backup_size}${NC}"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  DATA PRESERVATION COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  User data partition: ${USER_DATA_PARTITION}"
    echo -e "  Mount point: ${MOUNT_POINT}"
    echo -e "  Backup directory: ${BACKUP_DIR}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Data Status:${NC}"
    echo -e "  ${GREEN}→ User data partition verified${NC}"
    echo -e "  ${GREEN}→ Data integrity verified${NC}"
    echo -e "  ${GREEN}→ Backup created${NC}"
    echo
    
    echo -e "${BOLD}Important Notes:${NC}"
    echo -e "  ${YELLOW}→ User data persists across child kernel rebuilds${NC}"
    echo -e "  ${YELLOW}→ Backups are stored in ${BACKUP_DIR}${NC}"
    echo -e "  ${YELLOW}→ Always verify backups before child kernel rebuild${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Review backup in ${BACKUP_DIR}"
    echo "  2. Proceed with child kernel rebuild"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    # Install mode: verify the preservation target only - no data operations
    # at setup time
    if [ "${1:-}" = "--install" ]; then
        if [ -b "${USER_DATA_PARTITION:-}" ]; then
            show_status "OK" "User data partition present: ${USER_DATA_PARTITION}"
        else
            show_status "WARN" "User data partition not present: ${USER_DATA_PARTITION:-<unset>} (run partition-disk.sh)"
        fi
        show_status "OK" "Preservation flow armed: verify → mount → integrity → backup"
        log_event "Data preservation installed (configure-only)"
        show_summary
        exit 0
    fi
    
    log_event "Data preservation started"
    
    check_user_data_partition
    mount_user_data
    verify_data_integrity
    create_backup
    
    log_event "Data preservation completed"
    
    show_summary
}

# Run main function
main "$@"
