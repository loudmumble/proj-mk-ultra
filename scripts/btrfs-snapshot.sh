#!/usr/bin/env bash
# btrfs-snapshot.sh - Btrfs snapshot management for child rootfs
# SUSPICIOUS Framework: Advanced Security Feature

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

# Uses config: child-root-device (btrfs partition to snapshot)
CHILD_ROOT="${CHILD_ROOT_DEVICE:-/dev/sdb2}"
SNAPSHOT_DIR="/snapshots"

# Gate: snapshots are the Wave-3 advanced feature - no-op unless enabled
if [ "${BTRFS_SNAPSHOT_ENABLE:-false}" != "true" ]; then
    show_status "INFO" "Btrfs snapshots disabled by config (BTRFS_SNAPSHOT_ENABLE=false)"
    exit 0
fi
LOG_FILE="/var/log/proj-mk-ultra/btrfs-snapshot.log"

# Requires: btrfs-progs (pacman -S btrfs-progs)
show_status() {
    local status="$1"
    local message="$2"
    case "${status}" in
        OK)    echo -e "  ${GREEN}✓${NC} ${message}" ;;
        WARN)  echo -e "  ${YELLOW}⚠${NC} ${message}" ;;
        ERROR) echo -e "  ${RED}✗${NC} ${message}" ;;
        INFO)  echo -e "  ${BLUE}→${NC} ${message}" ;;
    esac
}

log_event() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

# Verify btrfs-progs is installed before any snapshot operations
check_btrfs() {
    if ! command -v btrfs &> /dev/null; then
        show_status "ERROR" "btrfs-progs not installed"
        show_status "INFO" "Install with: pacman -S btrfs-progs"
        return 1
    fi
    show_status "OK" "btrfs-progs found"
}

# Verify device is actually formatted as btrfs (prevents accidental ext4 snapshot)
check_btrfs_device() {
    local device="$1"
    
    if ! blkid -s TYPE -o value "${device}" 2>/dev/null | grep -- "btrfs" > /dev/null; then
        show_status "ERROR" "Device ${device} is not btrfs"
        return 1
    fi
    show_status "OK" "Device ${device} is btrfs"
}

# Snapshot the child root subvolume — CoW copy preserves current state
create_snapshot() {
    local snapshot_name="${1:-child-$(date +%Y%m%d-%H%M%S)}"
    local source_subvol="${2:-@}"
    
    echo -e "\n${BOLD}Creating btrfs snapshot...${NC}"
    
    show_status "INFO" "Source: ${CHILD_ROOT} (${source_subvol})"
    show_status "INFO" "Snapshot: ${snapshot_name}"
    
    mkdir -p "${SNAPSHOT_DIR}"
    
    local mount_point
    mount_point=$(mktemp -d)
    mount -t btrfs "${CHILD_ROOT}" "${mount_point}"
    
    if [ -d "${mount_point}/${source_subvol}" ]; then
        btrfs subvolume snapshot "${mount_point}/${source_subvol}" "${mount_point}/@snapshots/${snapshot_name}"
        show_status "OK" "Snapshot created: ${snapshot_name}"
        log_event "Snapshot created: ${snapshot_name}"
    else
        show_status "WARN" "Subvolume ${source_subvol} not found, creating from root"
        btrfs subvolume snapshot "${mount_point}" "${mount_point}/@snapshots/${snapshot_name}"
        show_status "OK" "Snapshot created from root: ${snapshot_name}"
        log_event "Snapshot created from root: ${snapshot_name}"
    fi
    
    umount "${mount_point}"
    rmdir "${mount_point}"
}

# Restore child root to a previous snapshot — destructive, requires confirmation
rollback_snapshot() {
    # Rollback rewrites the child root subvolume: a running child holds the
    # old subvolume busy and nested subvolumes are NOT restored by snapshot
    # semantics. Require the child stopped; document the nested limitation.
    if [ -d "${MULTIKERNEL_SYSFS:-/sys/fs/multikernel}/instances" ] && \
       ls -1 "${MULTIKERNEL_SYSFS:-/sys/fs/multikernel}/instances" 2>/dev/null | grep -- . > /dev/null; then
        show_status "ERROR" "Child instances exist - stop them before rollback (avoid busy subvolume + lost nested subvols)"
        exit 1
    fi
    local snapshot_name="$1"
    
    echo -e "\n${BOLD}Rolling back to snapshot: ${snapshot_name}${NC}"
    
    echo -e "${YELLOW}${BOLD}WARNING: This will overwrite current child rootfs${NC}"
    echo -e "${BOLD}Type 'YES' to continue: ${NC}"
    read -r confirmation
    
    if [ "${confirmation}" != "YES" ]; then
        show_status "ERROR" "Operation cancelled"
        return 1
    fi
    
    local mount_point
    mount_point=$(mktemp -d)
    mount -t btrfs "${CHILD_ROOT}" "${mount_point}"
    
    if [ -d "${mount_point}/@snapshots/${snapshot_name}" ]; then
        local current_subvol
        current_subvol=$(btrfs subvolume list "${mount_point}" | grep "@ " | awk '{print $NF}')
        
        if [ -n "${current_subvol}" ]; then
            btrfs subvolume delete "${mount_point}/${current_subvol}"
        fi
        
        btrfs subvolume snapshot "${mount_point}/@snapshots/${snapshot_name}" "${mount_point}/@"
        show_status "OK" "Rolled back to: ${snapshot_name}"
        log_event "Rolled back to: ${snapshot_name}"
    else
        show_status "ERROR" "Snapshot not found: ${snapshot_name}"
        umount "${mount_point}"
        rmdir "${mount_point}"
        return 1
    fi
    
    umount "${mount_point}"
    rmdir "${mount_point}"
}

list_snapshots() {
    echo -e "\n${BOLD}Available snapshots:${NC}"
    
    local mount_point
    mount_point=$(mktemp -d)
    mount -t btrfs "${CHILD_ROOT}" "${mount_point}"
    
    if [ -d "${mount_point}/@snapshots" ]; then
        btrfs subvolume list "${mount_point}/@snapshots" 2>/dev/null | awk '{print "  " $NF}'
    else
        show_status "INFO" "No snapshots found"
    fi
    
    umount "${mount_point}"
    rmdir "${mount_point}"
}

cleanup_old_snapshots() {
    local keep_count="${1:-5}"
    
    echo -e "\n${BOLD}Cleaning up old snapshots (keeping ${keep_count})...${NC}"
    
    local mount_point
    mount_point=$(mktemp -d)
    mount -t btrfs "${CHILD_ROOT}" "${mount_point}"
    
    if [ -d "${mount_point}/@snapshots" ]; then
        local snapshots
        snapshots=$(btrfs subvolume list "${mount_point}/@snapshots" 2>/dev/null | awk '{print $NF}' | sort -r)
        
        local count=0
        while IFS= read -r snapshot; do
            count=$((count + 1))
            if [ "${count}" -gt "${keep_count}" ]; then
                btrfs subvolume delete "${mount_point}/@snapshots/${snapshot}"
                show_status "OK" "Deleted: ${snapshot}"
                log_event "Deleted old snapshot: ${snapshot}"
            fi
        done <<< "${snapshots}"
        
        show_status "OK" "Cleanup complete"
    fi
    
    umount "${mount_point}"
    rmdir "${mount_point}"
}

show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  BTRFS SNAPSHOT MANAGEMENT${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Device: ${CHILD_ROOT}"
    echo -e "  Snapshot directory: ${SNAPSHOT_DIR}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  $0 create [name]     - Create snapshot"
    echo -e "  $0 rollback [name]   - Rollback to snapshot"
    echo -e "  $0 list              - List snapshots"
    echo -e "  $0 cleanup [count]   - Cleanup old snapshots"
    echo
}

main() {
    echo -e "${BOLD}PROJ-MK-ULTRA Btrfs Snapshot Manager${NC}"
    
    check_btrfs
    check_btrfs_device "${CHILD_ROOT}"
    
    case "${1:-}" in
        create)
            create_snapshot "${2:-}"
            ;;
        rollback)
            if [ -z "${2:-}" ]; then
                echo "Usage: $0 rollback <snapshot-name>"
                exit 1
            fi
            rollback_snapshot "$2"
            ;;
        list)
            list_snapshots
            ;;
        cleanup)
            cleanup_old_snapshots "${2:-5}"
            ;;
        *)
            show_summary
            ;;
    esac
}

main "$@"
