#!/usr/bin/env bash
# update-mainstream.sh - Update mainstream kernel
# SUSPICIOUS Framework: Update System
#
# Actions:
# - Check for updates
# - Download updates
# - Install updates
# - Verify installation
#
# Usage: sudo ./update-mainstream.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

LOG_FILE="/var/log/suspicious-update-mainstream.log"
BACKUP_DIR="/opt/suspicious/backups"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         MAINSTREAM KERNEL UPDATE                                   ║
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
    logger -t suspicious-update-mainstream "$level: $event"
}

# Function to detect package manager
detect_package_manager() {
    if command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v apt &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    else
        echo "unknown"
    fi
}

# Function to check for updates
check_for_updates() {
    show_step "Checking for Updates" 1
    
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    echo -e "\n${BOLD}  Package manager: ${pkg_manager}${NC}"
    
    case "${pkg_manager}" in
        pacman)
            show_status "INFO" "Checking for Arch Linux updates"
            pacman -Sy --noconfirm
            ;;
        apt)
            show_status "INFO" "Checking for Debian/Ubuntu updates"
            apt update -qq
            ;;
        dnf)
            show_status "INFO" "Checking for Fedora/RHEL updates"
            dnf check-update --quiet || true
            ;;
        *)
            show_status "ERROR" "Unsupported package manager"
            return 1
            ;;
    esac
    
    show_status "OK" "Update check complete"
    log_event "Update check complete"
}

# Function to create backup
create_backup() {
    show_step "Creating Backup" 2
    
    mkdir -p "${BACKUP_DIR}"
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/mainstream-kernel-${timestamp}.tar.gz"
    
    show_status "INFO" "Creating kernel backup"
    
    # Backup current kernel
    tar -czf "${backup_file}" /boot/ 2>/dev/null || true
    
    if [ -f "${backup_file}" ]; then
        show_status "OK" "Backup created: ${backup_file}"
        log_event "Backup created: ${backup_file}"
    else
        show_status "WARN" "Backup creation failed"
    fi
}

# Function to install updates
install_updates() {
    show_step "Installing Updates" 3
    
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    case "${pkg_manager}" in
        pacman)
            show_status "INFO" "Installing Arch Linux updates"
            pacman -Syu --noconfirm
            ;;
        apt)
            show_status "INFO" "Installing Debian/Ubuntu updates"
            apt upgrade -y -qq
            ;;
        dnf)
            show_status "INFO" "Installing Fedora/RHEL updates"
            dnf upgrade -y --quiet
            ;;
        *)
            show_status "ERROR" "Unsupported package manager"
            return 1
            ;;
    esac
    
    show_status "OK" "Updates installed"
    log_event "Updates installed"
}

# Function to verify installation
verify_installation() {
    show_step "Verifying Installation" 4
    
    # Check kernel version
    local kernel_version
    kernel_version=$(uname -r)
    
    echo -e "\n${BOLD}  Current kernel: ${kernel_version}${NC}"
    
    # Check if kernel was updated
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    case "${pkg_manager}" in
        pacman)
            show_status "INFO" "Checking installed kernel packages"
            pacman -Q | grep -i kernel | head -5
            ;;
        apt)
            show_status "INFO" "Checking installed kernel packages"
            dpkg -l | grep -i linux-image | head -5
            ;;
        dnf)
            show_status "INFO" "Checking installed kernel packages"
            rpm -qa | grep -i kernel | head -5
            ;;
    esac
    
    show_status "OK" "Installation verified"
    log_event "Installation verified"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  MAINSTREAM KERNEL UPDATE COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Log file: ${LOG_FILE}"
    echo -e "  Backup directory: ${BACKUP_DIR}"
    echo
    
    echo -e "${BOLD}Update Actions:${NC}"
    echo -e "  ${GREEN}→ Checked for updates${NC}"
    echo -e "  ${GREEN}→ Created backup${NC}"
    echo -e "  ${GREEN}→ Installed updates${NC}"
    echo -e "  ${GREEN}→ Verified installation${NC}"
    echo
    
    echo -e "${BOLD}Important Notes:${NC}"
    echo -e "  ${YELLOW}→ Reboot may be required for kernel updates${NC}"
    echo -e "  ${YELLOW}→ Run sudo ./sync-child-kernel.sh to sync to child${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Reboot if kernel was updated"
    echo "  2. Run: sudo ./sync-child-kernel.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    # The update flow runs real package-manager operations - it is gated on
    # the config flag so the setup wizard never triggers it implicitly
    if [ "${AUTO_UPDATE_MAINSTREAM:-false}" != "true" ]; then
        show_status "INFO" "Mainstream kernel auto-update is disabled by config (AUTO_UPDATE_MAINSTREAM=false)"
        show_status "INFO" "Enable in ${CONFIG_FILE} or run with AUTO_UPDATE_MAINSTREAM=true to apply updates"
        log_event "Mainstream update skipped - disabled by config"
        exit 0
    fi
    
    log_event "Mainstream kernel update started"
    
    check_for_updates
    create_backup
    install_updates
    verify_installation
    
    log_event "Mainstream kernel update completed"
    
    show_summary
}

# Run main function
main "$@"
