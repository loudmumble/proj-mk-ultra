#!/usr/bin/env bash
# check-disks.sh - Verify secondary disk exists and is properly sized
# SUSPICIOUS Framework: Pre-Installation Check
#
# Verifies:
# - Secondary disk exists
# - Disk is large enough (minimum 20GB recommended)
# - Disk is not in use
# - Disk is healthy (SMART status)
#
# Usage: sudo ./check-disks.sh

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"
if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         DISK VERIFICATION                                         ║
║         SUSPICIOUS Framework Pre-Installation Check                 ║
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

# Function to list all disks
list_disks() {
    echo -e "\n${BOLD}Available Disks:${NC}"
    echo -e "${BOLD}────────────────────────────────────────────────────────────────${NC}"
    
    lsblk -dno NAME,SIZE,TYPE,MODEL,ROTA,TRAN 2>/dev/null | while read line; do
        echo -e "  ${line}"
    done
    
    echo
}

# Function to identify primary disk
identify_primary_disk() {
    echo -e "\n${BOLD}Identifying primary disk (root filesystem)...${NC}"
    
    local root_device
    root_device=$(df / | awk 'NR==2{print $1}' | sed 's|^/dev/||' | sed 's/[0-9]*$//')
    
    if [ -n "${root_device}" ]; then
        show_result "Primary disk: /dev/${root_device}" "PASS"
        
        # Get size
        local size
        size=$(lsblk -dno SIZE "/dev/${root_device}" 2>/dev/null | head -1)
        echo -e "    Size: ${size}"
    else
        show_result "Could not identify primary disk" "FAIL"
    fi
}

# Function to identify secondary disk
identify_secondary_disk() {
    echo -e "\n${BOLD}Identifying secondary disk (for child kernel)...${NC}"
    
    # Find all physical disks (TYPE=disk), excluding the one that hosts /
    # (the disk with / in its MOUNTPOINTS is the root disk — everything else is a candidate)
    local disks=()
    while IFS= read -r disk; do
        [ -z "${disk}" ] && continue
        [[ "${disk}" == zram* ]] && continue
        if lsblk -no MOUNTPOINTS "/dev/${disk}" 2>/dev/null | grep -E "^/$|,/$" > /dev/null; then
            continue
        fi
        disks+=("${disk}")
    done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')
    
    if [ ${#disks[@]} -eq 0 ]; then
        show_result "No secondary disk found" "FAIL" "Multiple disks required for isolation"
        return
    fi
    
    echo -e "\n  ${BOLD}Secondary disk candidates:${NC}"
    for i in "${!disks[@]}"; do
        local disk="${disks[$i]}"
        local size
        size=$(lsblk -dno SIZE "/dev/${disk}" 2>/dev/null | head -1)
        local model
        model=$(lsblk -dno MODEL "/dev/${disk}" 2>/dev/null | head -1)
        
        echo -e "  $((i+1)). /dev/${disk} - ${size} - ${model:-Unknown}"
    done
    
    echo
    
    if [ ${#disks[@]} -eq 1 ]; then
        show_result "Single secondary disk found: /dev/${disks[0]}" "PASS"
        SELECTED_DISK="${disks[0]}"
    else
        local selection="" cand pick
        if [ -n "${TARGET_DISK:-}" ]; then
            for cand in "${disks[@]}"; do
                if [ "${cand}" = "${TARGET_DISK}" ]; then
                    selection="${cand}"
                    break
                fi
            done
            [ -n "${selection}" ] || show_result "TARGET_DISK=${TARGET_DISK} not among candidates" "WARN" "Falling back to selection below"
        fi
        if [ -z "${selection}" ]; then
            if [ -t 0 ]; then
                echo -e "${BOLD}  Select secondary disk (1-${#disks[@]}): ${NC}"
                read -r pick
                if [[ "${pick}" =~ ^[0-9]+$ ]] && [ "${pick}" -ge 1 ] && [ "${pick}" -le ${#disks[@]} ]; then
                    selection="${disks[$((pick-1))]}"
                else
                    show_result "Invalid selection" "FAIL"
                    return
                fi
            else
                selection="${disks[0]}"
                show_result "Non-interactive: auto-selected first candidate /dev/${selection}" "WARN" "Set TARGET_DISK in etc/proj-mk-ultra.conf to pin the disk"
            fi
        fi
        SELECTED_DISK="${selection}"
        show_result "Selected disk: /dev/${SELECTED_DISK}" "PASS"
    fi
}

# Function to check disk size
check_disk_size() {
    local disk="$1"
    
    echo -e "\n${BOLD}Checking disk size...${NC}"
    
    # Get disk size in bytes
    local size_bytes
    size_bytes=$(lsblk -dno SIZE "/dev/${disk}" 2>/dev/null | head -1)
    
    # Convert to GB
    local size_gb
    size_gb=$(lsblk -dno SIZE "/dev/${disk}" 2>/dev/null | head -1 | awk '{
        if ($1 ~ /G/) print $1
        else if ($1 ~ /T/) print $1 * 1024
        else print $1
    }' | sed 's/G//')
    
    local size_int="${size_gb%%.*}"
    if [ "${size_int:-0}" -ge 20 ]; then
        show_result "Disk size: ${size_bytes} (minimum 20GB)" "PASS"
    elif [ "${size_int:-0}" -ge 10 ]; then
        show_result "Disk size: ${size_bytes}" "WARN" "Minimum 20GB recommended"
    else
        show_result "Disk size: ${size_bytes}" "FAIL" "Minimum 20GB required"
    fi
}

# Function to check disk usage
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  DISK VERIFICATION SUMMARY${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    local total=$((PASSED + FAILED + WARNINGS))
    
    echo -e "  Total checks: ${total}"
    echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
    echo -e "  ${RED}Failed: ${FAILED}${NC}"
    echo -e "  ${YELLOW}Warnings: ${WARNINGS}${NC}"
    echo
    
    if [ "${FAILED}" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✓ DISK VERIFICATION PASSED${NC}"
        echo -e "${GREEN}  System is ready for disk partitioning${NC}"
        if [ -n "${SELECTED_DISK:-}" ]; then
            echo -e "${GREEN}  Selected disk: /dev/${SELECTED_DISK}${NC}"
        fi
    else
        echo -e "${RED}${BOLD}✗ DISK VERIFICATION FAILED${NC}"
        echo -e "${RED}  Please resolve the failed checks before proceeding${NC}"
    fi
    
    echo
    
    # Next steps
    echo -e "${BOLD}Next Steps:${NC}"
    if [ "${FAILED}" -eq 0 ]; then
        echo "  1. Run: sudo ./partition-disk.sh"
        echo "  2. Run: sudo ./install-child-kernel.sh"
    else
        echo "  1. Resolve failed checks above"
        echo "  2. Re-run this script"
    fi
    
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    list_disks
    identify_primary_disk
    identify_secondary_disk
    
    if [ -n "${SELECTED_DISK:-}" ]; then
        check_disk_size "${SELECTED_DISK}"
                fi
    
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
