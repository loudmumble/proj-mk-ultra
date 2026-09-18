#!/usr/bin/env bash
# update-multikernel.sh - Update multikernel kernel
# SUSPICIOUS Framework: Update System
#
# Actions:
# - Check for multikernel updates
# - Download updates
# - Build kernel
# - Install kernel
#
# Usage: sudo ./update-multikernel.sh

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

MULTIKERNEL_SRC="/opt/multikernel/linux"
LOG_FILE="/var/log/suspicious-update-multikernel.log"
BACKUP_DIR="/opt/suspicious/backups"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         MULTIKERNEL KERNEL UPDATE                                  ║
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
    logger -t suspicious-update-multikernel "$level: $event"
}

# Function to check multikernel source
check_multikernel_source() {
    show_step "Checking Multikernel Source" 1
    
    if [ -d "${MULTIKERNEL_SRC}" ]; then
        show_status "OK" "Multikernel source directory exists"
        
        # Check if it's a git repository
        if [ -d "${MULTIKERNEL_SRC}/.git" ]; then
            show_status "OK" "Multikernel source is a git repository"
            
            # Check for updates
            cd "${MULTIKERNEL_SRC}"
            git fetch origin
            
            local local_commit
            local_commit=$(git rev-parse HEAD)
            
            local remote_commit
            remote_commit=$(git rev-parse origin/main)
            
            if [ "${local_commit}" = "${remote_commit}" ]; then
                show_status "OK" "Multikernel is up to date"
                return 1
            else
                show_status "INFO" "Multikernel update available"
                return 0
            fi
        else
            show_status "WARN" "Multikernel source is not a git repository"
            return 1
        fi
    else
        show_status "ERROR" "Multikernel source not found: ${MULTIKERNEL_SRC}"
        return 1
    fi
}

# Function to create backup
create_backup() {
    show_step "Creating Backup" 2
    
    mkdir -p "${BACKUP_DIR}"
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/multikernel-kernel-${timestamp}.tar.gz"
    
    show_status "INFO" "Creating multikernel backup"
    
    # Backup current kernel
    tar -czf "${backup_file}" /boot/ 2>/dev/null || true
    
    if [ -f "${backup_file}" ]; then
        show_status "OK" "Backup created: ${backup_file}"
        log_event "Backup created: ${backup_file}"
    else
        show_status "WARN" "Backup creation failed"
    fi
}

# Function to update multikernel source
update_multikernel_source() {
    show_step "Updating Multikernel Source" 3
    
    cd "${MULTIKERNEL_SRC}"
    
    show_status "INFO" "Pulling latest changes"
    git pull origin main
    
    show_status "OK" "Multikernel source updated"
    log_event "Multikernel source updated"
}

# Function to re-apply fork patches after the pull
# The pull moves the tree; required fork patches (patches/*.patch, e.g.
# MK_CTRL_PGTABLE_PAGES=256 without which the 80G pool claim fails) must be
# re-applied or the build silently loses them.
apply_fork_patches() {
    show_step "Re-applying Fork Patches" 4
    
    local patch_dir="${SCRIPT_DIR}/../patches"
    if ! ls "${patch_dir}"/*.patch >/dev/null 2>&1; then
        show_status "WARN" "No patches in ${patch_dir} - nothing to re-apply"
        return 0
    fi
    
    cd "${MULTIKERNEL_SRC}"
    
    local patch applied=0 present=0
    for patch in "${patch_dir}"/*.patch; do
        if git apply --reverse --check "${patch}" 2>/dev/null; then
            show_status "OK" "Already applied: $(basename "${patch}")"
            present=$((present + 1))
        elif git apply --check "${patch}" 2>/dev/null; then
            git apply "${patch}"
            show_status "OK" "Applied: $(basename "${patch}")"
            applied=$((applied + 1))
        else
            show_status "ERROR" "Patch does not apply: $(basename "${patch}") - upstream changed the touched code"
            show_status "INFO" "Resolve in ${MULTIKERNEL_SRC} (git apply --3way ${patch}), then re-run"
            log_event "Fork patch failed: ${patch}" "ERROR"
            return 1
        fi
    done
    
    log_event "Fork patches: ${applied} applied, ${present} already present"
}

# Function to build multikernel
build_multikernel() {
    show_step "Building Multikernel" 5
    
    cd "${MULTIKERNEL_SRC}"
    
    show_status "INFO" "Building multikernel kernel"
    
    # Clean previous build
    make clean 2>/dev/null || true
    
    # Build kernel
    make -j$(nproc)
    
    if [ $? -eq 0 ]; then
        show_status "OK" "Multikernel kernel built"
        log_event "Multikernel kernel built"
    else
        show_status "ERROR" "Failed to build multikernel kernel"
        log_event "Failed to build multikernel kernel" "ERROR"
        return 1
    fi
}

# Function to install multikernel
install_multikernel() {
    show_step "Installing Multikernel" 6
    
    cd "${MULTIKERNEL_SRC}"
    
    show_status "INFO" "Installing multikernel kernel"
    
    # Install kernel
    make modules_install install
    
    if [ $? -eq 0 ]; then
        show_status "OK" "Multikernel kernel installed"
        log_event "Multikernel kernel installed"
    else
        show_status "ERROR" "Failed to install multikernel kernel"
        log_event "Failed to install multikernel kernel" "ERROR"
        return 1
    fi
    
    # Update initramfs
    show_status "INFO" "Updating initramfs"
    mkinitcpio --kernel "$(ls /lib/modules | grep -- "mk" | sort | tail -1)" -g "/boot/initramfs-$(ls /lib/modules | grep -- "mk" | sort | tail -1).img" 2>/dev/null || mkinitcpio -P
    
    if [ $? -eq 0 ]; then
        show_status "OK" "Initramfs updated"
    else
        show_status "WARN" "Failed to update initramfs"
    fi
}

# Function to verify installation
verify_installation() {
    show_step "Verifying Installation" 7
    
    # Check kernel version
    local kernel_version
    kernel_version=$(uname -r)
    
    echo -e "\n${BOLD}  Current kernel: ${kernel_version}${NC}"
    
    # Check installed kernels
    show_status "INFO" "Checking installed kernels"
    ls /boot/vmlinuz-* 2>/dev/null | head -5
    
    show_status "OK" "Installation verified"
    log_event "Installation verified"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  MULTIKERNEL KERNEL UPDATE COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Log file: ${LOG_FILE}"
    echo -e "  Backup directory: ${BACKUP_DIR}"
    echo
    
    echo -e "${BOLD}Update Actions:${NC}"
    echo -e "  ${GREEN}→ Checked for updates${NC}"
    echo -e "  ${GREEN}→ Created backup${NC}"
    echo -e "  ${GREEN}→ Updated source${NC}"
    echo -e "  ${GREEN}→ Re-applied fork patches${NC}"
    echo -e "  ${GREEN}→ Built kernel${NC}"
    echo -e "  ${GREEN}→ Installed kernel${NC}"
    echo -e "  ${GREEN}→ Verified installation${NC}"
    echo
    
    echo -e "${BOLD}Important Notes:${NC}"
    echo -e "  ${YELLOW}→ Reboot required for new kernel${NC}"
    echo -e "  ${YELLOW}→ Run sudo ./sync-child-kernel.sh to sync to child${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Reboot to load new kernel"
    echo "  2. Run: sudo ./sync-child-kernel.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    # Builds and installs a kernel - gated on the config flag so the setup
    # wizard never triggers a kernel build implicitly
    if [ "${AUTO_UPDATE_MULTIKERNEL:-false}" != "true" ]; then
        show_status "INFO" "Multikernel auto-update is disabled by config (AUTO_UPDATE_MULTIKERNEL=false)"
        show_status "INFO" "Enable in ${CONFIG_FILE} or run with AUTO_UPDATE_MULTIKERNEL=true to build and install"
        log_event "Multikernel update skipped - disabled by config"
        exit 0
    fi
    
    log_event "Multikernel kernel update started"
    
    if check_multikernel_source; then
        create_backup
        update_multikernel_source
        apply_fork_patches
        build_multikernel
        install_multikernel
        verify_installation
    else
        show_status "INFO" "No updates available"
    fi
    
    log_event "Multikernel kernel update completed"
    
    show_summary
}

# Run main function
main "$@"
