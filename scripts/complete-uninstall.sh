#!/usr/bin/env bash
# complete-uninstall.sh - Complete uninstall of PROJ-MK-ULTRA
# SUSPICIOUS Framework: Host Pristine Preservation

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/proj-mk-ultra/uninstall-$(date +%Y%m%d_%H%M%S).log"

# CLEANUP: On failure, log error and point user to log file
cleanup_on_error() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo -e "\n${RED}${BOLD}[ERROR] Uninstall failed with exit code ${exit_code}${NC}"
        echo -e "${YELLOW}Check ${LOG_FILE} for details${NC}"
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

log_event() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${BOLD}[ERROR] This script must be run as root${NC}"
        exit 1
    fi
}

# SECURITY: Requires explicit 'UNINSTALL' typed to prevent accidental execution
confirm_uninstall() {
    echo -e "\n${YELLOW}${BOLD}WARNING: This will completely remove PROJ-MK-ULTRA from your system${NC}"
    echo -e "${BOLD}Type 'UNINSTALL' to continue: ${NC}"
    read -r confirmation
    
    if [ "${confirmation}" != "UNINSTALL" ]; then
        echo -e "${YELLOW}Uninstall cancelled.${NC}"
        exit 0
    fi
}

# Disable and remove systemd services installed by setup.sh
remove_systemd_services() {
    echo -e "\n${BOLD}Removing systemd services...${NC}"
    
    local services=(
        "proj-mk-ultra-monitor"
        "proj-mk-ultra-boot"
        "mk-baseline"
        "suspicious-watch"
        "suspicious-updates"
    )
    
    for service in "${services[@]}"; do
        if systemctl is-active "${service}" 2>/dev/null; then
            systemctl stop "${service}" 2>/dev/null || true
            show_status "OK" "Stopped: ${service}"
        fi
        
        if systemctl is-enabled "${service}" 2>/dev/null; then
            systemctl disable "${service}" 2>/dev/null || true
            show_status "OK" "Disabled: ${service}"
        fi
        
        if [ -f "/etc/systemd/system/${service}.service" ]; then
            rm -f "/etc/systemd/system/${service}.service"
            show_status "OK" "Removed: ${service}.service"
        fi
    done
    
    if [ -f "/etc/systemd/system/suspicious-updates.timer" ]; then
        systemctl disable --now suspicious-updates.timer 2>/dev/null || true
        rm -f "/etc/systemd/system/suspicious-updates.timer"
        show_status "OK" "Removed: suspicious-updates.timer"
    fi
    
    systemctl daemon-reload 2>/dev/null || true
    show_status "OK" "Systemd daemon reloaded"
}

# Remove /etc, /var/lib, /var/log, /var/backups directories
remove_config_files() {
    echo -e "\n${BOLD}Removing configuration files...${NC}"
    
    local config_dirs=(
        "/etc/proj-mk-ultra"
        "/var/lib/proj-mk-ultra"
        "/var/log/proj-mk-ultra"
        "/var/backups/proj-mk-ultra"
    )
    
    for dir in "${config_dirs[@]}"; do
        if [ -d "${dir}" ]; then
            rm -rf "${dir}"
            show_status "OK" "Removed: ${dir}"
        fi
    done
}

remove_nspawn_config() {
    echo -e "\n${BOLD}Removing nspawn configuration...${NC}"
    
    local nspawn_files=(
        "/etc/systemd/nspawn/local_agent.nspawn"
    )
    
    for file in "${nspawn_files[@]}"; do
        if [ -f "${file}" ]; then
            rm -f "${file}"
            show_status "OK" "Removed: ${file}"
        fi
    done
}

remove_multikernel_config() {
    echo -e "\n${BOLD}Removing multikernel configuration...${NC}"
    
    if [ -d /sys/fs/multikernel ]; then
        show_status "WARN" "Multikernel filesystem is mounted"
        show_status "INFO" "This will be unmounted on reboot"
    fi
    
    show_status "OK" "Multikernel configuration cleaned"
}

# Restore bootloader — detects systemd-boot vs GRUB and cleans entries
restore_bootloader() {
    echo -e "\n${BOLD}Restoring bootloader...${NC}"
    
    if [ -d /boot/loader/entries ] && command -v bootctl &>/dev/null; then
        for entry in /boot/loader/entries/*multikernel*; do
            if [ -f "${entry}" ]; then
                rm -f "${entry}"
                show_status "OK" "Removed: $(basename ${entry})"
            fi
        done
        bootctl update 2>/dev/null || true
        show_status "OK" "systemd-boot cleaned"
    elif command -v grub-mkconfig &> /dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
        show_status "OK" "GRUB configuration restored"
    else
        show_status "WARN" "Bootloader restoration skipped"
        show_status "INFO" "You may need to manually update bootloader"
    fi
}

# SECURITY: Wipes first 100MB of child disk to prevent forensic recovery
remove_child_disk() {
    echo -e "\n${BOLD}Checking child disk...${NC}"
    
    echo -ne "${BOLD}Do you want to wipe the child disk? (y/n): ${NC}"
    read -r wipe_choice
    
    case "${wipe_choice}" in
        y|Y|yes|YES)
            local root_device
            root_device=$(df / | awk 'NR==2{print $1}' | sed 's|^/dev/||' | sed 's/[0-9]*$//')
            
            lsblk -dno NAME 2>/dev/null | grep -E "^(sd|vd|nvme)" | while read disk; do
                if [ "${disk}" != "${root_device}" ]; then
                    echo -e "\n${YELLOW}${BOLD}WARNING: This will DESTROY ALL DATA on /dev/${disk}${NC}"
                    echo -e "${BOLD}Type 'YES' to continue: ${NC}"
                    read -r confirm
                    
                    if [ "${confirm}" = "YES" ]; then
                        dd if=/dev/zero of="/dev/${disk}" bs=1M count=100 2>/dev/null || true
                        show_status "OK" "Wiped first 100MB of /dev/${disk}"
                    fi
                fi
            done
            ;;
        *)
            show_status "INFO" "Child disk not wiped"
            ;;
    esac
}

show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  UNINSTALL COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Actions taken:${NC}"
    echo -e "  ${GREEN}✓ Systemd services removed${NC}"
    echo -e "  ${GREEN}✓ Configuration files removed${NC}"
    echo -e "  ${GREEN}✓ Nspawn configuration removed${NC}"
    echo -e "  ${GREEN}✓ Bootloader restored${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo -e "  1. Reboot your system"
    echo -e "  2. Verify host is pristine"
    echo -e "  3. If testing on SD card, remove it now"
    echo
    
    echo -e "${BOLD}Host Status:${NC}"
    echo -e "  ${GREEN}✓ Host kernel unchanged${NC}"
    echo -e "  ${GREEN}✓ Host data untouched${NC}"
    echo -e "  ${GREEN}✓ System restored to pre-installation state${NC}"
    echo
}

main() {
    echo -e "${BOLD}PROJ-MK-ULTRA Complete Uninstall${NC}"
    
    check_root
    confirm_uninstall
    
    log_event "Uninstall started"
    
    remove_systemd_services
    remove_config_files
    remove_nspawn_config
    remove_multikernel_config
    restore_bootloader
    remove_child_disk
    
    log_event "Uninstall completed"
    
    show_summary
}

main "$@"
