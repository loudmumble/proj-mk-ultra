#!/usr/bin/env bash
# sd-card-setup.sh - Setup SD card for testing
# SUSPICIOUS Framework: Testing Infrastructure

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

ROOT_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"
USER_DATA_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"

# CLEANUP: On failure, warn about partial SD card state
cleanup_on_error() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo -e "\n${RED}${BOLD}[ERROR] SD card setup failed with exit code ${exit_code}${NC}"
        echo -e "${YELLOW}SD card may be in partial state - verify before reuse${NC}"
    fi
    exit ${exit_code}
}

trap cleanup_on_error EXIT

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

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${BOLD}[ERROR] This script must be run as root${NC}"
        exit 1
    fi
}

# Scan /sys/block for removable devices (SD cards, USB drives)
detect_removable_storage() {
    echo -e "\n${BOLD}Detecting removable storage...${NC}"
    
    local devices=()
    
    while IFS= read -r line; do
        local dev=$(echo "${line}" | awk '{print $1}')
        local size=$(echo "${line}" | awk '{print $2}')
        local model=$(echo "${line}" | awk '{print $3}')
        
        if [ -b "/dev/${dev}" ]; then
            local removable
            removable=$(cat "/sys/block/${dev}/removable" 2>/dev/null || echo "0")
            
            if [ "${removable}" = "1" ]; then
                devices+=("${dev}|${size}|${model}")
                echo -e "  ${GREEN}✓${NC} /dev/${dev} - ${size} - ${model}"
            fi
        fi
    done < <(lsblk -dno NAME,SIZE,MODEL 2>/dev/null | grep -E "^(sd|mmc)" | sed 's/^├─//;s/^└─//')
    
    if [ ${#devices[@]} -eq 0 ]; then
        show_status "WARN" "No removable storage detected"
        show_status "INFO" "Insert SD card and run this script again"
        return 1
    fi
    
    echo
    echo -e "${BOLD}Select device (1-${#devices[@]}): ${NC}"
    read -r selection
    
    if [[ "${selection}" =~ ^[0-9]+$ ]] && [ "${selection}" -ge 1 ] && [ "${selection}" -le ${#devices[@]} ]; then
        local selected="${devices[$((selection-1))]}"
        local dev=$(echo "${selected}" | cut -d'|' -f1)
        local size=$(echo "${selected}" | cut -d'|' -f2)
        local model=$(echo "${selected}" | cut -d'|' -f3)
        
        echo -e "\n${BOLD}Selected: /dev/${dev} (${size}, ${model})${NC}"
        
        check_sd_card_speed "/dev/${dev}"
        
        echo "${dev}"
    else
        show_status "ERROR" "Invalid selection"
        return 1
    fi
}

# Check UHS speed class from device CID register
check_sd_card_speed() {
    local device="$1"
    
    echo -e "\n${BOLD}Checking SD card speed...${NC}"
    
    local card_type
    card_type=$(cat "/sys/block/$(basename ${device})/device/type" 2>/dev/null || echo "unknown")
    
    local uhs_support
    uhs_support=$(cat "/sys/block/$(basename ${device})/device/cid" 2>/dev/null | grep -o "UHS-[IⅡⅢ]" || echo "unknown")
    
    if [ "${uhs_support}" != "unknown" ]; then
        show_status "OK" "UHS support: ${uhs_support}"
        show_status "INFO" "Recommended for testing"
    else
        show_status "WARN" "UHS support: Unknown or not supported"
        show_status "INFO" "Testing may be slower"
        show_status "INFO" "Recommended: UHS-I or faster (100MB/s+)"
    fi
}

# SECURITY: Requires explicit 'YES' typed before destructive format
format_sd_card() {
    local device="$1"
    
    echo -e "\n${BOLD}Formatting SD card...${NC}"
    
    echo -e "${YELLOW}${BOLD}WARNING: This will DESTROY ALL DATA on /dev/${device}${NC}"
    echo -e "${BOLD}Type 'YES' to continue: ${NC}"
    read -r confirmation
    
    if [ "${confirmation}" != "YES" ]; then
        show_status "ERROR" "Operation cancelled"
        return 1
    fi
    
    show_status "INFO" "Unmounting partitions..."
    for partition in /dev/${device}*; do
        umount "${partition}" 2>/dev/null || true
    done
    
    show_status "INFO" "Creating GPT partition table..."
    parted -s "/dev/${device}" mklabel gpt
    
    local boot_end_mib=$(( $(echo "${CHILD_BOOT_SIZE:-512M}" | tr -d 'Mm') ))
    local root_end_mib=$(( boot_end_mib + $(echo "${CHILD_ROOT_SIZE:-20G}" | sed 's/G$//' ) * 1024 ))
    
    show_status "INFO" "Creating boot partition (${CHILD_BOOT_SIZE:-512M})..."
    parted -s "/dev/${device}" mkpart primary fat32 1MiB "${boot_end_mib}MiB"
    parted -s "/dev/${device}" set 1 esp on
    
    show_status "INFO" "Creating root partition (${CHILD_ROOT_SIZE:-20G}, ${ROOT_FILESYSTEM})..."
    parted -s "/dev/${device}" mkpart primary ${ROOT_FILESYSTEM} "${boot_end_mib}MiB" "${root_end_mib}MiB"
    
    show_status "INFO" "Creating user data partition (remaining, ${USER_DATA_FILESYSTEM})..."
    parted -s "/dev/${device}" mkpart primary ${USER_DATA_FILESYSTEM} "${root_end_mib}MiB" 100%
    
    sleep 2
    
    show_status "INFO" "Formatting partitions..."
    mkfs.fat -F 32 -n BOOT "/dev/${device}1"
    mkfs."${ROOT_FILESYSTEM}" -L ROOT "/dev/${device}2"
    mkfs."${USER_DATA_FILESYSTEM}" -L USERDATA "/dev/${device}3"
    
    show_status "OK" "SD card formatted"
}

show_summary() {
    local device="$1"
    
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  SD CARD READY${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Device: /dev/${device}"
    echo -e "  Partitions:"
    echo -e "    /dev/${device}1 - Boot (FAT32, 512MB)"
    echo -e "    /dev/${device}2 - Root (${ROOT_FILESYSTEM}, 20GB)"
    echo -e "    /dev/${device}3 - User Data (${USER_DATA_FILESYSTEM}, remaining)"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo -e "  1. Run: sudo ./2_setup.sh"
    echo -e "  2. Select 'SD card' as installation target"
    echo -e "  3. Complete installation wizard"
    echo -e "  4. Reboot and select SD card in BIOS/UEFI"
    echo -e "  5. Test child kernel instances"
    echo -e "  6. When done, run: sudo ./scripts/complete-uninstall.sh"
    echo -e "  7. Remove SD card, host remains pristine"
    echo
}

main() {
    echo -e "${BOLD}PROJ-MK-ULTRA SD Card Setup${NC}"
    
    check_root
    
    local device
    device=$(detect_removable_storage)
    
    if [ -z "${device}" ]; then
        exit 1
    fi
    
    format_sd_card "${device}"
    show_summary "${device}"
}

main "$@"
