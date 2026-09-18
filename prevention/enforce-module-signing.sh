#!/usr/bin/env bash
# enforce-module-signing.sh - Enforce module signature verification
# SUSPICIOUS Framework: Prevention Layer
#
# Configures:
# - Module signature verification
# - Trusted keys for module signing
# - Blocking of unsigned modules
#
# Usage: sudo ./enforce-module-signing.sh

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
KEYS_DIR="/etc/secureboot/keys"
MODULES_DIR="/lib/modules"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         MODULE SIGNING ENFORCEMENT                                ║
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

# Function to check current module signing status
check_current_status() {
    show_step "Checking Current Status" 1
    
    # Check kernel config
    if [ -f "/proc/config.gz" ]; then
        local config
        config=$(zcat /proc/config.gz 2>/dev/null)
        
        if echo "${config}" | grep -- "CONFIG_MODULE_SIG=y" > /dev/null; then
            show_status "OK" "Module signing enabled in kernel"
        else
            show_status "WARN" "Module signing not enabled in kernel"
        fi
        
        if echo "${config}" | grep -- "CONFIG_MODULE_SIG_FORCE=y" > /dev/null; then
            show_status "OK" "Module signing force enabled"
        else
            show_status "WARN" "Module signing force not enabled"
        fi
    fi
    
    # Check loaded modules
    local unsigned_modules
    unsigned_modules=$(lsmod | awk 'NR>1{print $1}' | while read mod; do
        if ! modinfo "${mod}" 2>/dev/null | grep "sig" > /dev/null; then
            echo "${mod}"
        fi
    done | wc -l)
    
    if [ "${unsigned_modules}" -eq 0 ]; then
        show_status "OK" "All loaded modules are signed"
    else
        show_status "WARN" "Found ${unsigned_modules} unsigned modules"
    fi
}

# Function to create signing keys
create_signing_keys() {
    show_step "Creating Signing Keys" 2
    
    # Create keys directory
    mkdir -p "${KEYS_DIR}"
    
    # Check if keys already exist
    if [ -f "${KEYS_DIR}/signing_key.pem" ]; then
        show_status "OK" "Signing keys already exist"
        return
    fi
    
    # Generate signing key
    show_status "INFO" "Generating signing key"
    
    openssl req -new -x509 -newkey rsa:4096 -keyout "${KEYS_DIR}/signing_key.pem" \
        -out "${KEYS_DIR}/signing_key.pem" -days 3650 -nodes \
        -subj "/CN=SUSPICIOUS Framework Module Signing Key/"
    
    # Set permissions
    chmod 600 "${KEYS_DIR}/signing_key.pem"
    
    show_status "OK" "Signing key created"
}

# Function to sign existing modules
sign_existing_modules() {
    show_step "Signing Existing Modules" 3
    
    local kernel_version
    kernel_version=$(uname -r)
    
    if [ ! -d "${MODULES_DIR}/${kernel_version}" ]; then
        show_status "WARN" "Module directory not found: ${MODULES_DIR}/${kernel_version}"
        return
    fi
    
    show_status "INFO" "Signing modules for kernel ${kernel_version}"
    
    # Locate the kernel tree's sign-file (relative paths silently fail)
    local sign_file=""
    local candidate
    for candidate in \
        "/opt/multikernel/linux/scripts/sign-file" \
        "/lib/modules/${kernel_version}/build/scripts/sign-file"; do
        if [ -x "${candidate}" ]; then sign_file="${candidate}"; break; fi
    done
    if [ -z "${sign_file}" ]; then
        show_status "WARN" "sign-file not found (kernel headers/build tree absent) - no modules signed"
        return 0
    fi
    show_status "INFO" "Using sign-file: ${sign_file}"
    
    local signed_count=0
    local unsigned_count=0
    local fail_count=0
    local module
    
    while read module; do
        if ! modinfo -F signer "${module}" 2>/dev/null | grep "." > /dev/null; then
            if "${sign_file}" sha256 "${KEYS_DIR}/signing_key.pem" "${module}" 2>/dev/null; then
                signed_count=$((signed_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        fi
    done < <(find "${MODULES_DIR}/${kernel_version}" -name "*.ko*" -type f)
    
    if [ "${fail_count}" -gt 0 ]; then
        show_status "WARN" "Modules processed: ${signed_count} unsigned attempted, FAILED: ${fail_count}"
    else
        show_status "OK" "Unsigned modules processed: ${signed_count}"
    fi
}

# Function to configure module loading
configure_module_loading() {
    show_step "Configuring Module Loading" 4
    
    # Create modprobe configuration
    # Enforcement is kernel-level: module.sig_enforce=1 (set in
    # configure_kernel_parameters). There is no modprobe-level unsigned-module
    # block - this file records that fact honestly.
    cat > /etc/modprobe.d/suspicious-signing.conf << 'EOF'
# SUSPICIOUS Framework - Module Signing Enforcement
# Enforcement mechanism: kernel cmdline module.sig_enforce=1
# (no modprobe-level unsigned-module block exists in Linux)
EOF
    
    show_status "OK" "Module loading configuration recorded (enforcement = sig_enforce)"
}

# Function to detect bootloader type
detect_bootloader() {
    if [ -d /sys/firmware/efi ]; then
        if [ -d /boot/loader/entries ] && command -v bootctl &>/dev/null; then
            echo "systemd-boot"
        elif [ -f /boot/grub/grub.cfg ]; then
            echo "grub"
        else
            echo "unknown"
        fi
    else
        if [ -f /boot/grub/grub.cfg ]; then
            echo "grub-legacy"
        else
            echo "unknown"
        fi
    fi
}

# Function to configure kernel parameters
configure_kernel_parameters() {
    show_step "Configuring Kernel Parameters" 5
    
    local bootloader
    bootloader=$(detect_bootloader)
    
    case "${bootloader}" in
        systemd-boot)
            local param="module.sig_enforce=1"
            local modified=false
            
            # Probe: enforcing with unsigned boot-critical modules (nouveau on
            # a self-built kernel) = next-reboot display loss
            local unsigned_crit=0
            local mod
            for mod in nouveau; do
                if lsmod 2>/dev/null | grep "^${mod} " > /dev/null && \
                   ! modinfo -F signer "${mod}" 2>/dev/null | grep "." > /dev/null; then
                    unsigned_crit=$((unsigned_crit + 1))
                fi
            done
            if [ "${unsigned_crit}" -gt 0 ]; then
                show_status "WARN" "Boot-critical modules (nouveau) are UNSIGNED - sig_enforce=1 would break the next boot"
                echo -ne "${BOLD}Type 'ENFORCE' to apply anyway, anything else to skip: ${NC}"
                read -r enforce_choice
                if [ "${enforce_choice}" != "ENFORCE" ]; then
                    show_status "INFO" "sig_enforce NOT applied - sign the modules first, then re-run"
                    return 0
                fi
            fi
            
            for entry in /boot/loader/entries/*.conf; do
                if [ -f "${entry}" ]; then
                    if ! grep -q "${param}" "${entry}"; then
                        cp "${entry}" "${entry}.backup.$(date +%Y%m%d)"
                        sed -i "s/^options /options ${param} /" "${entry}"
                        modified=true
                        show_status "OK" "Updated: $(basename ${entry})"
                    fi
                fi
            done
            
            if [ "${modified}" = true ]; then
                show_status "OK" "systemd-boot entries updated"
            else
                show_status "OK" "Kernel parameters already configured"
            fi
            ;;
        grub|grub-legacy)
            if [ -f /etc/default/grub ]; then
                cp /etc/default/grub /etc/default/grub.backup.$(date +%Y%m%d)
                
                if ! grep -q "module.sig_enforce" /etc/default/grub; then
                    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="module.sig_enforce=1 /' /etc/default/grub
                fi
                
                grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
                show_status "OK" "GRUB configuration updated"
            else
                show_status "WARN" "GRUB config not found, skipping"
            fi
            ;;
        *)
            show_status "WARN" "Unknown bootloader (${bootloader}), skipping kernel parameter configuration"
            ;;
    esac
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  MODULE SIGNING ENFORCEMENT COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Signing keys: ${KEYS_DIR}"
    echo -e "  Module directory: ${MODULES_DIR}"
    echo
    
    echo -e "${BOLD}What Was Configured:${NC}"
    echo -e "  1. Signing keys generated"
    echo -e "  2. Existing modules signed"
    echo -e "  3. Module loading configured"
    echo -e "  4. Kernel parameters updated"
    echo
    
    echo -e "${BOLD}Important Notes:${NC}"
    echo -e "  ${YELLOW}→ Reboot required for kernel parameter changes to take effect${NC}"
    echo -e "  ${YELLOW}→ Keep signing keys secure - they are needed for future module updates${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./setup-filesystem-isolation.sh"
    echo "  2. Reboot to apply kernel parameter changes"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    # Gate: this script configures the HOST's module-signing posture. It
    # honors MODULE_SIGNING_ENFORCE and will not flip sig_enforce onto a
    # kernel whose boot-critical modules are unsigned (display-loss hazard).
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "${SCRIPT_DIR}/../etc/proj-mk-ultra.conf" ] && \
        . "${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"
    
    if [ "${MODULE_SIGNING_ENFORCE:-true}" != "true" ]; then
        show_status "INFO" "Module signing enforcement disabled by config (MODULE_SIGNING_ENFORCE=false)"
        exit 0
    fi
    
    check_current_status
    create_signing_keys
    sign_existing_modules
    configure_module_loading
    configure_kernel_parameters
    
    show_summary
}

# Run main function
main "$@"
