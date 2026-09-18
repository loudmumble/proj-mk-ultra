#!/usr/bin/env bash
# multi-kernel-update.sh - Complete Multikernel Update Manager
# SUSPICIOUS Framework: Kernel Update Orchestration
#
# Updates all multikernel components in correct order:
# 1. Mainstream kernel packages
# 2. Multikernel kernel from source
# 3. Child kernel modules
# 4. Verification and rollback support
#
# Usage: sudo ./multi-kernel-update.sh [command]

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

MULTIKERNEL_SRC="/opt/multikernel/linux"
CHILD_ROOT="/mnt/child-root"
# Uses config: child-root-device
CHILD_ROOT_PARTITION="${CHILD_ROOT_DEVICE:-/dev/sdb2}"
LOG_FILE="/var/log/proj-mk-ultra/multi-kernel-update.log"
BACKUP_DIR="/var/backup/multikernel-kernels"

log_event() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

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

check_prerequisites() {
    echo -e "\n${BOLD}Checking prerequisites...${NC}"
    
    if [ "$(id -u)" -ne 0 ]; then
        show_status "ERROR" "Must run as root"
        exit 1
    fi
    show_status "OK" "Running as root"
    
    if [ ! -d "${MULTIKERNEL_SRC}" ]; then
        show_status "ERROR" "Multikernel source not found: ${MULTIKERNEL_SRC}"
        exit 1
    fi
    show_status "OK" "Multikernel source found"
    
    if ! command -v git &> /dev/null; then
        show_status "ERROR" "git not installed"
        exit 1
    fi
    show_status "OK" "git installed"
}

# Preserve current kernel for rollback if update fails
backup_current_kernel() {
    echo -e "\n${BOLD}Backing up current kernel...${NC}"
    
    mkdir -p "${BACKUP_DIR}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local current_version=$(uname -r)
    local backup_path="${BACKUP_DIR}/kernel-${current_version}-${timestamp}"
    
    mkdir -p "${backup_path}"
    
    cp /boot/vmlinuz-linux "${backup_path}/" 2>/dev/null || true
    cp /boot/initramfs-linux.img "${backup_path}/" 2>/dev/null || true
    cp -r /lib/modules/${current_version} "${backup_path}/" 2>/dev/null || true
    
    log_event "Backed up kernel ${current_version} to ${backup_path}"
    show_status "OK" "Kernel backed up to ${backup_path}"
}

# Update distro kernel packages (pacman/apt/dnf auto-detected)
update_mainstream() {
    echo -e "\n${BOLD}Updating mainstream kernel packages...${NC}"
    
    if command -v pacman &> /dev/null; then
        show_status "INFO" "Detected Arch Linux - using pacman"
        pacman -Syu --noconfirm linux linux-headers 2>&1 | tail -5
    elif command -v apt &> /dev/null; then
        show_status "INFO" "Detected Debian/Ubuntu - using apt"
        apt update && apt upgrade -y linux-image-generic linux-headers-generic 2>&1 | tail -5
    elif command -v dnf &> /dev/null; then
        show_status "INFO" "Detected Fedora/RHEL - using dnf"
        dnf update -y kernel kernel-headers 2>&1 | tail -5
    else
        show_status "WARN" "Unknown package manager - skipping mainstream update"
        return 0
    fi
    
    log_event "Updated mainstream kernel packages"
    show_status "OK" "Mainstream kernel updated"
}

# Pull latest multikernel source from git, compare commit hashes
update_multikernel_source() {
    echo -e "\n${BOLD}Updating multikernel from source...${NC}"
    
    cd "${MULTIKERNEL_SRC}"
    
    local before_hash=$(git rev-parse HEAD)
    show_status "INFO" "Current commit: ${before_hash:0:8}"
    
    git fetch origin 2>&1 | tail -3
    
    local remote_hash=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null)
    
    if [ "${before_hash}" = "${remote_hash}" ]; then
        show_status "OK" "Already up to date"
        return 0
    fi
    
    show_status "INFO" "New version available: ${remote_hash:0:8}"
    
    git stash 2>/dev/null || true
    git pull origin main 2>&1 || git pull origin master 2>&1
    
    log_event "Updated multikernel source from ${before_hash:0:8} to ${remote_hash:0:8}"
    show_status "OK" "Multikernel source updated"
}

# Build kernel from source: oldconfig -> make -> modules_install -> install
build_multikernel() {
    echo -e "\n${BOLD}Building multikernel...${NC}"
    
    cd "${MULTIKERNEL_SRC}"
    
    show_status "INFO" "Running make oldconfig..."
    make olddefconfig 2>&1 | tail -3
    
    show_status "INFO" "Building kernel (this may take a while)..."
    local required="CONFIG_MULTIKERNEL=y CONFIG_OF=y CONFIG_OF_OVERLAY=y"
    local missing=""
    local opt
    for opt in ${required}; do
        grep -q "^${opt}$" .config || missing="${missing} ${opt%%=*}"
    done
    if [ -n "${missing}" ]; then
        show_status "ERROR" "Required kernel config flags missing:${missing} - ABORT (enable in .config and re-run)"
        return 1
    fi
    show_status "OK" "Required kernel flags verified"
    
    make -j$(nproc) 2>&1 | tail -5
    
    show_status "INFO" "Installing modules..."
    make modules_install 2>&1 | tail -3
    
    show_status "INFO" "Installing kernel..."
    make install 2>&1 | tail -3
    
    log_event "Built and installed multikernel"
    show_status "OK" "Multikernel built successfully"
}

# Copy host kernel modules into child root partition
update_child_modules() {
    echo -e "\n${BOLD}Updating child kernel modules...${NC}"
    
    if [ ! -d "${CHILD_ROOT}" ]; then
        show_status "WARN" "Child root not mounted at ${CHILD_ROOT}"
        show_status "INFO" "Attempting to mount..."
        
        mkdir -p "${CHILD_ROOT}"
        if mount "${CHILD_ROOT_PARTITION}" "${CHILD_ROOT}" 2>/dev/null; then
            show_status "OK" "Child root mounted"
        else
            show_status "ERROR" "Failed to mount child root"
            return 1
        fi
    fi
    
    local current_version=$(uname -r)
    local modules_dir="/lib/modules/${current_version}"
    
    if [ -d "${modules_dir}" ]; then
        show_status "INFO" "Copying modules to child root..."
        cp -r "${modules_dir}" "${CHILD_ROOT}/lib/modules/" 2>/dev/null
        show_status "OK" "Modules copied"
    else
        show_status "WARN" "No modules found for ${current_version}"
    fi
    
    log_event "Updated child kernel modules"
}

# Regenerate initramfs for all installed kernels
update_initramfs() {
    echo -e "\n${BOLD}Updating initramfs...${NC}"
    
    if command -v mkinitcpio &> /dev/null; then
        show_status "INFO" "Running mkinitcpio -P..."
        mkinitcpio -P 2>&1 | tail -3
    elif command -v update-initramfs &> /dev/null; then
        show_status "INFO" "Running update-initramfs..."
        update-initramfs -u 2>&1 | tail -3
    elif command -v dracut &> /dev/null; then
        show_status "INFO" "Running dracut..."
        dracut --force 2>&1 | tail -3
    else
        show_status "WARN" "Unknown initramfs generator"
        return 0
    fi
    
    log_event "Updated initramfs"
    show_status "OK" "Initramfs updated"
}

# Post-update sanity checks: kernel image, initramfs, modules, multikernel module
verify_update() {
    echo -e "\n${BOLD}Verifying update...${NC}"
    
    local issues=0
    
    if [ -f /boot/vmlinuz-linux ]; then
        show_status "OK" "Kernel image present"
    else
        show_status "ERROR" "Kernel image missing"
        issues=$((issues + 1))
    fi
    
    if [ -f /boot/initramfs-linux.img ]; then
        show_status "OK" "Initramfs present"
    else
        show_status "ERROR" "Initramfs missing"
        issues=$((issues + 1))
    fi
    
    local current_version=$(uname -r)
    if [ -d "/lib/modules/${current_version}" ]; then
        show_status "OK" "Modules present for ${current_version}"
    else
        show_status "WARN" "Modules not found for current version"
    fi
    
    if lsmod | grep -- multikernel > /dev/null; then
        show_status "OK" "Multikernel module loaded"
    else
        show_status "WARN" "Multikernel module not loaded (may need reboot)"
    fi
    
    if [ ${issues} -eq 0 ]; then
        log_event "Update verification passed"
        show_status "OK" "All checks passed"
    else
        log_event "Update verification found ${issues} issues"
        show_status "ERROR" "Verification found ${issues} issues"
    fi
    
    return ${issues}
}

rollback_kernel() {
    echo -e "\n${BOLD}Rolling back to previous kernel...${NC}"
    
    if [ ! -d "${BACKUP_DIR}" ]; then
        show_status "ERROR" "No backups found in ${BACKUP_DIR}"
        exit 1
    fi
    
    echo -e "\n${BOLD}Available backups:${NC}"
    local backups=($(ls -1d "${BACKUP_DIR}"/kernel-* 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        show_status "ERROR" "No backups available"
        exit 1
    fi
    
    for i in "${!backups[@]}"; do
        local backup="${backups[$i]}"
        local name=$(basename "${backup}")
        echo "  $((i+1))) ${name}"
    done
    
    echo -ne "\n${BOLD}Select backup to restore [1-${#backups[@]}]: ${NC}"
    read -r choice
    
    if [ -z "${choice}" ] || [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${#backups[@]}" ]; then
        show_status "ERROR" "Invalid selection"
        exit 1
    fi
    
    local selected="${backups[$((choice-1))]}"
    show_status "INFO" "Restoring from: $(basename "${selected}")"
    
    if [ -f "${selected}/vmlinuz-linux" ]; then
        cp "${selected}/vmlinuz-linux" /boot/vmlinuz-linux
        show_status "OK" "Kernel image restored"
    fi
    
    if [ -f "${selected}/initramfs-linux.img" ]; then
        cp "${selected}/initramfs-linux.img" /boot/initramfs-linux.img
        show_status "OK" "Initramfs restored"
    fi
    
    if [ -d "${selected}/modules" ]; then
        cp -r "${selected}/modules/"* /lib/modules/
        show_status "OK" "Modules restored"
    fi
    
    log_event "Rolled back to $(basename "${selected}")"
    show_status "OK" "Rollback complete - reboot required"
}

show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  MULTI-KERNEL UPDATE MANAGER${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  ${GREEN}update${NC}          Update all components"
    echo -e "  ${GREEN}mainstream${NC}      Update mainstream kernel only"
    echo -e "  ${GREEN}source${NC}          Update multikernel source only"
    echo -e "  ${GREEN}build${NC}           Build multikernel only"
    echo -e "  ${GREEN}modules${NC}         Update child modules only"
    echo -e "  ${GREEN}verify${NC}          Verify current installation"
    echo -e "  ${GREEN}rollback${NC}        Rollback to previous kernel"
    echo -e "  ${GREEN}status${NC}          Show current kernel info"
    echo
}

show_current_status() {
    echo -e "\n${BOLD}Current Kernel Status:${NC}"
    
    echo "  Kernel version: $(uname -r)"
    echo "  Architecture:   $(uname -m)"
    echo "  Multikernel src: ${MULTIKERNEL_SRC}"
    
    if [ -d "${MULTIKERNEL_SRC}" ]; then
        cd "${MULTIKERNEL_SRC}"
        local hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        local branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        echo "  Source branch:  ${branch}"
        echo "  Source commit:  ${hash}"
    fi
    
    echo "  Child root:     ${CHILD_ROOT}"
    if mountpoint -q "${CHILD_ROOT}" 2>/dev/null; then
        echo "  Child mounted:  yes"
    else
        echo "  Child mounted:  no"
    fi
    
    echo "  Backups:        ${BACKUP_DIR}"
    if [ -d "${BACKUP_DIR}" ]; then
        local count=$(ls -1d "${BACKUP_DIR}"/kernel-* 2>/dev/null | wc -l)
        echo "  Backup count:   ${count}"
    fi
    
    echo
}

main() {
    local command="${1:-help}"
    shift || true
    
    case "${command}" in
        update)
            # Deliberate manual tool - still honors the config flag unless --force
            if [ "${2:-}" != "--force" ] && \
               ! grep -q '^AUTO_UPDATE_MULTIKERNEL="true"' "${CONFIG_FILE:-/nonexistent}" 2>/dev/null && \
               [ "${AUTO_UPDATE_MULTIKERNEL:-false}" != "true" ]; then
                show_status "INFO" "AUTO_UPDATE_MULTIKERNEL=false - use '$0 update --force' to override"
                exit 0
            fi
            check_prerequisites
            backup_current_kernel
            update_mainstream
            update_multikernel_source
            build_multikernel
            update_child_modules
            update_initramfs
            verify_update
            echo -e "\n${GREEN}${BOLD}Update complete! Reboot recommended.${NC}"
            ;;
        mainstream)
            check_prerequisites
            update_mainstream
            ;;
        source)
            check_prerequisites
            update_multikernel_source
            ;;
        build)
            check_prerequisites
            build_multikernel
            ;;
        modules)
            check_prerequisites
            update_child_modules
            ;;
        initramfs)
            check_prerequisites
            update_initramfs
            ;;
        verify)
            verify_update
            ;;
        rollback)
            check_prerequisites
            rollback_kernel
            ;;
        status)
            show_current_status
            ;;
        help|*)
            show_summary
            ;;
    esac
}

main "$@"
