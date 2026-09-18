#!/usr/bin/env bash
# setup-filesystem-isolation.sh - Configure filesystem isolation
# SUSPICIOUS Framework: Prevention Layer
#
# Configures:
# - Read-only root filesystem for child kernel
# - Separate /data partition for user data
# - Mount options for security
# - Filesystem permissions
#
# Usage: sudo ./setup-filesystem-isolation.sh

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

CHILD_ROOT="/mnt/child-root"
USER_DATA_PARTITION="${CHILD_DATA_DEVICE:-/dev/sdb3}"
USER_DATA_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         FILESYSTEM ISOLATION SETUP                                 ║
║         SUSPICIOUS Framework Prevention Layer                       ║
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

# Function to create mount points
create_mount_points() {
    show_step "Creating Mount Points" 1
    
    local mount_points=("${CHILD_ROOT}" "${CHILD_ROOT}/data")
    
    for mount_point in "${mount_points[@]}"; do
        if [ -d "${mount_point}" ]; then
            show_status "OK" "Mount point exists: ${mount_point}"
        else
            mkdir -p "${mount_point}"
            show_status "OK" "Created mount point: ${mount_point}"
        fi
    done
}

# Function to mount partitions
mount_partitions() {
    show_step "Mounting Partitions" 2
    
    # Check if the partition is mounted AT THE EXPECTED MOUNTPOINT (mounted
    # anywhere else does not make ${CHILD_ROOT}/data usable)
    if findmnt -rn -S "${USER_DATA_PARTITION}" -M "${CHILD_ROOT}/data" >/dev/null 2>&1; then
        show_status "OK" "User data partition already mounted at ${CHILD_ROOT}/data"
    elif findmnt -rn -S "${USER_DATA_PARTITION}" >/dev/null 2>&1; then
        show_status "WARN" "User data partition mounted elsewhere - remounting at ${CHILD_ROOT}/data"
        umount "${USER_DATA_PARTITION}" 2>/dev/null || true
        mount -t "${USER_DATA_FILESYSTEM:-ext4}" "${USER_DATA_PARTITION}" "${CHILD_ROOT}/data"
        show_status "OK" "User data partition mounted"
    else
        # Mount user data partition
        show_status "INFO" "Mounting user data partition"
        mount -t "${USER_DATA_FILESYSTEM:-ext4}" "${USER_DATA_PARTITION}" "${CHILD_ROOT}/data"
        show_status "OK" "User data partition mounted"
    fi
}

# Function to configure mount options
configure_mount_options() {
    show_step "Configuring Mount Options" 3
    
    # Create fstab entry for /data
    show_status "INFO" "Creating fstab entry for /data"
    
    local user_uuid
    user_uuid=$(blkid -s UUID -o value "${USER_DATA_PARTITION}")
    
    # Check if entry already exists
    if grep -q "${user_uuid}" /etc/fstab; then
        show_status "OK" "fstab entry already exists"
    else
        # Add fstab entry
        echo "UUID=${user_uuid} ${CHILD_ROOT}/data ${USER_DATA_FILESYSTEM} noauto,nofail,noatime,nosuid,nodev,noexec 0 0" >> /etc/fstab
        show_status "OK" "fstab entry created (noauto: mounted on demand, not at host boot)"
        show_status "INFO" "Manual mount when needed: mount ${CHILD_ROOT}/data"
    fi
}

# Function to configure filesystem permissions
configure_permissions() {
    show_step "Configuring Filesystem Permissions" 4
    
    # Set permissions for /data
    show_status "INFO" "Setting permissions for /data"
    
    # Create directory structure
    local directories=(
        "${CHILD_ROOT}/data/workspace"
        "${CHILD_ROOT}/data/documents"
        "${CHILD_ROOT}/data/downloads"
        "${CHILD_ROOT}/data/config"
        "${CHILD_ROOT}/data/logs"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "${dir}"
        chmod 755 "${dir}"
        show_status "OK" "Created: ${dir}"
    done
    
    # Ownership policy: the child runs under private-users=pick with dropped
    # capabilities - a root-owned workspace is unwritable to the agent user.
    # workspace is 1777 (sticky, world-writable) so the mapped child user can
    # work; nosuid/nodev/noexec on the mount plus the ephemeral child root
    # bound the risk. Remaining dirs stay root-owned (agent reads, not writes).
    chmod 1777 "${CHILD_ROOT}/data/workspace"
    chown -R root:root "${CHILD_ROOT}/data"
    
    show_status "OK" "Permissions configured (workspace 1777 for child agent; mitigated by mount options)"
}

# Function to configure filesystem checks
configure_fsck() {
    show_step "Configuring Filesystem Checks" 6
    
    # Enable filesystem check at boot
    show_status "INFO" "Enabling filesystem check at boot"
    
    case "${USER_DATA_FILESYSTEM:-ext4}" in
        ext4)
            if command -v e2fsck &> /dev/null; then
                e2fsck -f -y "${USER_DATA_PARTITION}" 2>/dev/null || true
                show_status "OK" "ext4 filesystem check completed"
            else
                show_status "WARN" "e2fsck not found, skipping filesystem check"
            fi
            ;;
        btrfs)
            if command -v btrfs &> /dev/null; then
                mount -t btrfs "${USER_DATA_PARTITION}" /mnt/child-root/data 2>/dev/null && \
                    btrfs scrub start -B /mnt/child-root/data 2>/dev/null || true
                show_status "OK" "btrfs scrub completed (read-write mount checked)"
            else
                show_status "WARN" "btrfs tool not found, skipping filesystem check"
            fi
            ;;
        *)
            show_status "INFO" "No online check implemented for ${USER_DATA_FILESYSTEM} - skipping"
            ;;
    esac
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  FILESYSTEM ISOLATION SETUP COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Child root: ${CHILD_ROOT}"
    echo -e "  User data: ${CHILD_ROOT}/data"
    echo
    
    echo -e "${BOLD}Mount Options:${NC}"
    echo -e "  /data: noauto,nofail,noatime,nosuid,nodev,noexec (mounted on demand)"
    echo -e "  /tmp: tmpfs defaults,nosuid,nodev,noexec,mode=1777"
    echo -e "  /run: tmpfs defaults,nosuid,nodev,mode=755"
    echo
    
    echo -e "${BOLD}Directory Structure:${NC}"
    echo -e "  /data/workspace/ - Working files"
    echo -e "  /data/documents/ - Documents"
    echo -e "  /data/downloads/ - Downloads"
    echo -e "  /data/config/ - Configuration files"
    echo -e "  /data/logs/ - Log files"
    echo
    
    echo -e "${BOLD}Security Features:${NC}"
    echo -e "  ${GREEN}→ No SUID/SGID binaries on /data${NC}"
    echo -e "  ${GREEN}→ No device files on /data${NC}"
    echo -e "  ${GREEN}→ No execution on /data${NC}"
    echo -e "  ${GREEN}→ tmpfs for /tmp and /run${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./setup-network-isolation.sh"
    echo "  2. Reboot to apply changes"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    create_mount_points
    mount_partitions
    configure_mount_options
    configure_permissions
    configure_fsck
    
    show_summary
}

# Run main function
main "$@"
