#!/usr/bin/env bash
# partition-disk.sh - Partition secondary disk for child kernel
# SUSPICIOUS Framework: Pre-Installation
#
# Creates:
# - /dev/sdX1 - Boot partition (512MB)
# - /dev/sdX2 - Root partition (20GB)
# - /dev/sdX3 - User data partition (remaining space)
#
# Usage: sudo ./partition-disk.sh

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

ROOT_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"
USER_DATA_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"

# Leapfrog: child disk uses a different filesystem than the host so poisoned
# metadata payloads cannot cross the boundary
if [ "${CHILD_LEAPFROG_FS_ENABLE:-false}" = "true" ] && [ -n "${CHILD_LEAPFROG_FS:-}" ]; then
    ROOT_FILESYSTEM="${CHILD_LEAPFROG_FS}"
    USER_DATA_FILESYSTEM="${CHILD_LEAPFROG_FS}"
fi

BOOT_SIZE="${CHILD_BOOT_SIZE:-512M}"
ROOT_SIZE="${CHILD_ROOT_SIZE:-20G}"
USER_DATA_SIZE="${CHILD_DATA_SIZE:-100%}"

# Convert a size like 512M / 10G / 10752MiB to MiB (integer)
size_to_mib() {
    local size="$1"
    case "${size}" in
        *MiB) echo "${size%MiB}" ;;
        *M)   echo "${size%M}" ;;
        *G)   echo $(( ${size%G} * 1024 )) ;;
        *)    echo "${size}" ;;
    esac
}

cleanup_on_error() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo -e "\n${RED}${BOLD}[ERROR] Script failed with exit code ${exit_code}${NC}"
        echo -e "${YELLOW}Cleaning up any partial operations...${NC}"
        umount /mnt/child-root 2>/dev/null || true
    fi
    exit ${exit_code}
}

trap cleanup_on_error EXIT

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         DISK PARTITIONING                                         ║
║         SUSPICIOUS Framework Pre-Installation                      ║
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

# Function to select disk
select_disk() {
    show_step "Select Disk" 1
    
    # Check if target disk is defined in config (accepts bare name or /dev/ path)
    if [ -n "${TARGET_DISK:-}" ]; then
        # Accept bare names, /dev/ paths, AND stable by-id paths - by-id
        # survives USB letter flips (observed twice on the reference build);
        # resolve everything to the bare kernel name for the partN construction.
        local configured_disk
        case "${TARGET_DISK}" in
            /dev/*) configured_disk=$(basename "$(readlink -f "${TARGET_DISK}" 2>/dev/null)") ;;
            *)      configured_disk="${TARGET_DISK}" ;;
        esac
        if [ -b "/dev/${configured_disk}" ]; then
            SELECTED_DISK="${configured_disk}"
        fi
    fi
    
    if [ -z "${SELECTED_DISK:-}" ]; then
        echo -e "${BOLD}Available disks:${NC}"
        echo -e "${BOLD}────────────────────────────────────────────────────────────────${NC}"

        lsblk -dno NAME,SIZE,TYPE,MODEL 2>/dev/null | while read line; do
            echo -e "  ${line}"
        done

        echo

        # Find all physical disks that are NOT the root disk
        local root_device
        root_device=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || true)
        local disks=()
        while IFS= read -r disk; do
            [ -z "${disk}" ] && continue
            [ "${disk}" = "${root_device}" ] && continue
            disks+=("${disk}")
        done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')

        if [ ${#disks[@]} -eq 0 ]; then
            show_status "ERROR" "No secondary disk found"
            exit 1
        fi
        
        if [ ${#disks[@]} -eq 1 ]; then
            SELECTED_DISK="${disks[0]}"
            show_status "OK" "Using single secondary disk: /dev/${SELECTED_DISK}"
        else
            echo -e "${BOLD}Select disk (1-${#disks[@]}): ${NC}"
            if [ ! -t 0 ]; then
                show_status "ERROR" "Multiple candidate disks and no TTY - set TARGET_DISK in etc/proj-mk-ultra.conf"
                exit 1
            fi
            read -r selection
            
            if [[ "${selection}" =~ ^[0-9]+$ ]] && [ "${selection}" -ge 1 ] && [ "${selection}" -le ${#disks[@]} ]; then
                SELECTED_DISK="${disks[$((selection-1))]}"
                show_status "OK" "Selected disk: /dev/${SELECTED_DISK}"
            else
                show_status "ERROR" "Invalid selection"
                exit 1
            fi
        fi
    fi
}

# Function to confirm operation
confirm_partition() {
    show_step "Confirm Operation" 2
    
    echo -e "${YELLOW}${BOLD}WARNING: This will DESTROY ALL DATA on /dev/${SELECTED_DISK}${NC}"
    echo
    echo -e "${BOLD}Planned partition layout:${NC}"
    echo -e "  /dev/${SELECTED_DISK}1 - Boot partition (${BOOT_SIZE})"
    echo -e "  /dev/${SELECTED_DISK}2 - Root partition (${ROOT_SIZE})"
    echo -e "  /dev/${SELECTED_DISK}3 - User data partition (${USER_DATA_SIZE} of remaining)"
    echo

    # Existing deployment gate: filesystems already on this disk mean a
    # prior deployment (or any data). Destructive-by-enter is unacceptable
    # there - demand an explicit WIPE with empty default (abort on enter).
    local existing
    existing=$(blkid "/dev/${SELECTED_DISK}1" "/dev/${SELECTED_DISK}2" "/dev/${SELECTED_DISK}3" 2>/dev/null | wc -l)
    if [ "${existing}" -gt 0 ]; then
        echo -e "${RED}${BOLD}EXISTING DEPLOYMENT DETECTED: ${existing} filesystem(s) already on /dev/${SELECTED_DISK}${NC}"
        blkid "/dev/${SELECTED_DISK}1" "/dev/${SELECTED_DISK}2" "/dev/${SELECTED_DISK}3" 2>/dev/null | sed 's/^/    /'
        echo
        echo -e "${BOLD}Type 'WIPE' to destroy them, or press Enter to abort: ${NC}"
        if [ -t 0 ]; then read -r confirmation; else confirmation="${PARTITION_CONFIRM:-}"; fi
        if [ "${confirmation}" != "WIPE" ]; then
            show_status "ERROR" "Operation cancelled - existing deployment preserved"
            exit 1
        fi
    else
        echo -e "${BOLD}Type 'YES' to continue: ${NC}"
        if [ -t 0 ]; then read -r confirmation; else confirmation="${PARTITION_CONFIRM:-}"; fi
        if [ "${confirmation}" != "YES" ]; then
            show_status "ERROR" "Operation cancelled"
            exit 1
        fi
    fi
    
    show_status "OK" "Operation confirmed"
}

# Function to unmount any mounted partitions
unmount_partitions() {
    show_step "Unmounting Partitions" 3
    
    # Check for mounted partitions
    local mounted
    mounted=$(mount | grep "/dev/${SELECTED_DISK}" || true)
    
    if [ -n "${mounted}" ]; then
        show_status "WARN" "Found mounted partitions"
        
        # Unmount all partitions
        for partition in /dev/${SELECTED_DISK}*; do
            if mount | grep "${partition}" > /dev/null; then
                show_status "INFO" "Unmounting ${partition}"
                umount "${partition}" 2>/dev/null || true
            fi
        done
        
        show_status "OK" "All partitions unmounted"
    else
        show_status "OK" "No mounted partitions found"
    fi
}

# Function to create partition table
create_partition_table() {
    show_step "Creating Partition Table" 4
    
    show_status "INFO" "Creating GPT partition table"
    
    # Create GPT partition table
    parted -s "/dev/${SELECTED_DISK}" mklabel gpt
    
    show_status "OK" "GPT partition table created"
}

# Function to create partitions
create_partitions() {
    show_step "Creating Partitions" 5
    
    local boot_end_mib
    boot_end_mib=$(size_to_mib "${BOOT_SIZE}")
    local root_end_mib=$(( boot_end_mib + $(size_to_mib "${ROOT_SIZE}") ))
    
    show_status "INFO" "Creating boot partition (${BOOT_SIZE})"
    parted -s "/dev/${SELECTED_DISK}" mkpart primary fat32 1MiB "${boot_end_mib}MiB"
    parted -s "/dev/${SELECTED_DISK}" set 1 esp on
    
    show_status "INFO" "Creating primary root partition (${ROOT_SIZE})"
    parted -s "/dev/${SELECTED_DISK}" mkpart primary "${ROOT_FILESYSTEM}" "${boot_end_mib}MiB" "${root_end_mib}MiB"
    
    show_status "INFO" "Creating user data partition (${USER_DATA_SIZE})"
    local disk_bytes
    disk_bytes=$(lsblk -bno SIZE "/dev/${SELECTED_DISK}" 2>/dev/null | head -1)
    local disk_mib=$(( disk_bytes / 1048576 ))
    local data_end_mib
    case "${USER_DATA_SIZE}" in
        *%)
            local pct="${USER_DATA_SIZE%\%}"
            data_end_mib=$(( root_end_mib + (disk_mib - root_end_mib) * pct / 100 ))
            ;;
        *)
            data_end_mib=$(( root_end_mib + $(size_to_mib "${USER_DATA_SIZE}") ))
            ;;
    esac
    # Keep 1MiB off the disk end: the GPT backup header owns the last sectors
    # and parted rejects partitions that overlap it.
    [ "${data_end_mib}" -gt $(( disk_mib - 1 )) ] && data_end_mib=$(( disk_mib - 1 ))
    parted -s "/dev/${SELECTED_DISK}" mkpart primary "${USER_DATA_FILESYSTEM}" "${root_end_mib}MiB" "${data_end_mib}MiB"
    
    show_status "OK" "Partitions created"
}

# Function to format partitions
format_partitions() {
    show_step "Formatting Partitions" 6
    
    sleep 2
    
    show_status "INFO" "Formatting boot partition as FAT32"
    mkfs.fat -F 32 -n BOOT "/dev/${SELECTED_DISK}1"
    
    show_status "INFO" "Formatting root partition as ${ROOT_FILESYSTEM}"
    case "${ROOT_FILESYSTEM}" in
        btrfs) mkfs.btrfs -f -L ROOT "/dev/${SELECTED_DISK}2" ;;
        ext4)  mkfs.ext4  -F -L ROOT "/dev/${SELECTED_DISK}2" ;;
        *)     mkfs."${ROOT_FILESYSTEM}" -L ROOT "/dev/${SELECTED_DISK}2" ;;
    esac

    show_status "INFO" "Formatting user data partition as ${USER_DATA_FILESYSTEM}"
    case "${USER_DATA_FILESYSTEM}" in
        btrfs) mkfs.btrfs -f -L USERDATA "/dev/${SELECTED_DISK}3" ;;
        ext4)  mkfs.ext4  -F -L USERDATA "/dev/${SELECTED_DISK}3" ;;
        *)     mkfs."${USER_DATA_FILESYSTEM}" -L USERDATA "/dev/${SELECTED_DISK}3" ;;
    esac
    
    show_status "OK" "Partitions formatted"
}

# Function to verify partition layout
verify_partitions() {
    show_step "Verifying Partition Layout" 7
    
    echo -e "${BOLD}Partition layout:${NC}"
    lsblk -f "/dev/${SELECTED_DISK}" 2>/dev/null
    
    echo
    
    # Verify partition count — lsblk -lno lists the disk AND its children;
    # subtract 1 for the disk line itself to get the partition count.
    local partition_count
    partition_count=$(lsblk -lno NAME "/dev/${SELECTED_DISK}" 2>/dev/null | grep -c "^${SELECTED_DISK}[0-9]" || true)

    if [ "${partition_count}" -eq 3 ]; then
        show_status "OK" "Partition count: ${partition_count} (expected 3)"
    else
        show_status "ERROR" "Partition count: ${partition_count} (expected 3)"
    fi
}

# Function to persist discovered devices back to the config file so downstream
# scripts (monitors, sync, recovery) read the real paths instead of fallbacks
persist_disk_config() {
    show_step "Saving Disk Configuration" 8
    
    if [ ! -f "${CONFIG_FILE}" ]; then
        show_status "WARN" "Config file not found, skipping device persistence"
        return 0
    fi
    
    # Prefer stable by-id symlinks (USB letter flips observed on the
    # reference build); fall back to kernel paths when by-id is absent.
    local part_path
    part_path() {
        local n="$1" p
        p=$(udevadm info -q symlink -n "/dev/${SELECTED_DISK}${n}" 2>/dev/null | tr ' ' '\n' | grep '^disk/by-id/' | head -1 || true)
        if [ -n "${p}" ]; then echo "/dev/${p}"; else echo "/dev/${SELECTED_DISK}${n}"; fi
    }
    local disk_id disk_ref="/dev/${SELECTED_DISK}"
    disk_id=$(udevadm info -q symlink -n "/dev/${SELECTED_DISK}" 2>/dev/null | tr ' ' '\n' | grep '^disk/by-id/' | head -1 || true)
    [ -n "${disk_id}" ] && disk_ref="/dev/${disk_id}"

    local key value
    for pair in "TARGET_DISK=${disk_ref}" \
                "CHILD_BOOT_DEVICE=$(part_path 1)" \
                "CHILD_ROOT_DEVICE=$(part_path 2)" \
                "CHILD_DATA_DEVICE=$(part_path 3)"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        if grep -q "^${key}=" "${CONFIG_FILE}"; then
            sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${CONFIG_FILE}"
        else
            echo "${key}=\"${value}\"" >> "${CONFIG_FILE}"
        fi
    done
    
    show_status "OK" "Disk devices persisted to ${CONFIG_FILE}"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  PARTITIONING COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Disk: /dev/${SELECTED_DISK}"
    echo -e "  Partitions:"
    echo -e "    /dev/${SELECTED_DISK}1 - Boot (FAT32, ${BOOT_SIZE})"
    echo -e "    /dev/${SELECTED_DISK}2 - Root (${ROOT_FILESYSTEM}, ${ROOT_SIZE})"
    echo -e "    /dev/${SELECTED_DISK}3 - User Data (${USER_DATA_FILESYSTEM}, ${USER_DATA_SIZE})"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./install-child-kernel.sh"
    echo "  2. Run: sudo ./setup-updates.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    select_disk
    confirm_partition
    unmount_partitions
    create_partition_table
    create_partitions
    format_partitions
    verify_partitions
    persist_disk_config
    
    show_summary
}

# Run main function
main "$@"
