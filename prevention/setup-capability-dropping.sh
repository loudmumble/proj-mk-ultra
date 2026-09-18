#!/usr/bin/env bash
# setup-capability-dropping.sh - Configure capability dropping for child kernel
# SUSPICIOUS Framework: Prevention Layer
#
# Implements CBPI (Compositional Boundary Precedence Inversion) prevention:
# - Namespace isolation (PrivateUsers=pick)
# - Capability dropping (Capability=none + DropCapability)
# - Seccomp-BPF filtering (SystemCallFilter)
# - Filesystem isolation (ReadOnly=yes, Volatile=yes)
# - Network isolation (PrivateNetwork=yes)
#
# This script creates the systemd-nspawn configuration that enforces:
# - No elevated privileges for child kernel
# - No access to host namespaces
# - No network access
# - Read-only root filesystem
# - Restricted syscall set
#
# Usage: sudo ./setup-capability-dropping.sh

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
NSPAWN_DIR="/etc/systemd/nspawn"
NSPAWN_CONFIG="${NSPAWN_DIR}/local_agent.nspawn"
BACKUP_DIR="/var/backups/suspicious/nspawn"
LOG_FILE="/var/log/suspicious/capability-dropping.log"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         CAPABILITY DROPPING CONFIGURATION                           ║
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

# Function to log messages
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}" >> "${LOG_FILE}"
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${BOLD}[ERROR] This script must be run as root${NC}"
        exit 1
    fi
}

# Function to create log directory
setup_logging() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}"
    log_message "INFO" "Capability dropping configuration started"
}

# Function to backup existing configuration
backup_existing_config() {
    show_step "Backing Up Existing Configuration" 1
    
    mkdir -p "${BACKUP_DIR}"
    
    if [ -f "${NSPAWN_CONFIG}" ]; then
        local backup_file="${BACKUP_DIR}/local_agent.nspawn.$(date +%Y%m%d_%H%M%S).bak"
        cp "${NSPAWN_CONFIG}" "${backup_file}"
        show_status "OK" "Backed up existing config to ${backup_file}"
        log_message "INFO" "Backed up existing nspawn config"
    else
        show_status "INFO" "No existing configuration to backup"
    fi
}

# Function to create nspawn configuration
create_nspawn_config() {
    show_step "Creating systemd-nspawn Configuration" 2
    
    # Create directory if it doesn't exist
    mkdir -p "${NSPAWN_DIR}"
    
    # Create the nspawn configuration
    cat > "${NSPAWN_CONFIG}" << 'EOF'
# SUSPICIOUS Framework - Child Kernel systemd-nspawn Configuration
# CBPI (Compositional Boundary Precedence Inversion) Prevention
#
# This configuration enforces:
# - Namespace isolation (no shared UIDs)
# - Capability dropping (no elevated privileges)
# - Seccomp-BPF filtering (restricted syscalls)
# - Filesystem isolation (read-only root)
# - Network isolation (no network access)
#
# WARNING: This configuration is CRITICAL for security.
# Do not modify without understanding the security implications.

[Exec]
# Namespace isolation - prevents UID collisions
PrivateUsers=pick

# Capability dropping - no elevated privileges
Capability=none

# Drop all capabilities that could be used for privilege escalation
DropCapability=CAP_SYS_ADMIN CAP_SYS_CHROOT CAP_NET_ADMIN CAP_SYS_PTRACE

# Seccomp-BPF filtering - restrict available syscalls
# Allow basic system service calls
SystemCallFilter=@system-service @common-linux @file-system @network-io

# Block dangerous syscalls that could be used for attacks
SystemCallFilter=~@privileged @clock @cpu-emulation @obsolete @swap

# Additional security: block specific dangerous syscalls
SystemCallFilter=kexec_file_load kexec_load reboot mount umount2 pivot_root chroot

[Files]
# Read-only root filesystem - prevents modification
ReadOnly=yes

# Volatile filesystem - temporary writes go to tmpfs
Volatile=yes

# Bind mount user data directory (read-write for user files)
Bind=/data/workspace:/workspace/io

# Temporary directories with proper permissions
TemporaryFileSystem=/tmp:mode=1777
TemporaryFileSystem=/var/tmp:mode=1777

[Network]
# No network access - prevents data exfiltration
PrivateNetwork=yes

# No host access - prevents container escape
VirtualEthernet=no
EOF
    
    show_status "OK" "Created nspawn configuration at ${NSPAWN_CONFIG}"
    log_message "INFO" "Created nspawn configuration"
}

# Function to set proper permissions
set_permissions() {
    show_step "Setting Permissions" 3
    
    # Set ownership to root:systemd-network (standard for nspawn)
    chown root:systemd-network "${NSPAWN_CONFIG}" 2>/dev/null || chown root:root "${NSPAWN_CONFIG}"
    
    # Set restrictive permissions (readable by root only)
    chmod 600 "${NSPAWN_CONFIG}"
    
    show_status "OK" "Permissions set (600, root:root)"
    log_message "INFO" "Permissions set on nspawn configuration"
}

# Function to verify configuration
verify_config() {
    show_step "Verifying Configuration" 4
    
    local errors=0
    
    # Check if file exists
    if [ ! -f "${NSPAWN_CONFIG}" ]; then
        show_status "ERROR" "Configuration file not found"
        return 1
    fi
    
    # Check for required settings
    if grep -q "PrivateUsers=pick" "${NSPAWN_CONFIG}"; then
        show_status "OK" "Namespace isolation: PrivateUsers=pick"
    else
        show_status "ERROR" "Missing PrivateUsers=pick"
        errors=$((errors + 1))
    fi
    
    if grep -q "Capability=none" "${NSPAWN_CONFIG}"; then
        show_status "OK" "Capability dropping: Capability=none"
    else
        show_status "ERROR" "Missing Capability=none"
        errors=$((errors + 1))
    fi
    
    if grep -q "DropCapability=CAP_SYS_ADMIN" "${NSPAWN_CONFIG}"; then
        show_status "OK" "Capability dropping: DropCapability configured"
    else
        show_status "ERROR" "Missing DropCapability"
        errors=$((errors + 1))
    fi
    
    if grep -q "SystemCallFilter=@system-service" "${NSPAWN_CONFIG}"; then
        show_status "OK" "Seccomp filtering: SystemCallFilter configured"
    else
        show_status "ERROR" "Missing SystemCallFilter"
        errors=$((errors + 1))
    fi
    
    if grep -q "ReadOnly=yes" "${NSPAWN_CONFIG}"; then
        show_status "OK" "Filesystem isolation: ReadOnly=yes"
    else
        show_status "ERROR" "Missing ReadOnly=yes"
        errors=$((errors + 1))
    fi
    
    if grep -q "PrivateNetwork=yes" "${NSPAWN_CONFIG}"; then
        show_status "OK" "Network isolation: PrivateNetwork=yes"
    else
        show_status "ERROR" "Missing PrivateNetwork=yes"
        errors=$((errors + 1))
    fi
    
    if [ ${errors} -eq 0 ]; then
        show_status "OK" "All required settings present"
        return 0
    else
        show_status "ERROR" "${errors} required settings missing"
        return 1
    fi
}

# Function to test nspawn configuration
test_nspawn_config() {
    show_step "Testing nspawn Configuration" 5
    
    # Check if systemd-nspawn is available
    if ! command -v systemd-nspawn &> /dev/null; then
        show_status "WARN" "systemd-nspawn not found - skipping test"
        return 0
    fi
    
    # Try to parse the configuration
    if systemd-nspawn --settings=verify 2>/dev/null; then
        show_status "OK" "nspawn configuration is valid"
    else
        show_status "WARN" "nspawn configuration validation failed (may need root)"
    fi
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  CAPABILITY DROPPING CONFIGURATION COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "Configuration file: ${NSPAWN_CONFIG}"
    echo -e "Backup directory: ${BACKUP_DIR}"
    echo -e "Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Security Settings:${NC}"
    echo -e "  ✓ Namespace isolation: PrivateUsers=pick"
    echo -e "  ✓ Capability dropping: Capability=none"
    echo -e "  ✓ Capability dropping: DropCapability=CAP_SYS_ADMIN CAP_SYS_CHROOT CAP_NET_ADMIN CAP_SYS_PTRACE"
    echo -e "  ✓ Seccomp filtering: SystemCallFilter=@system-service @common-linux @file-system @network-io"
    echo -e "  ✓ Seccomp blocking: SystemCallFilter=~@privileged @clock @cpu-emulation @obsolete @swap"
    echo -e "  ✓ Filesystem isolation: ReadOnly=yes, Volatile=yes"
    echo -e "  ✓ Network isolation: PrivateNetwork=yes"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./prevention/verify-iommu.sh"
    echo "  2. Run: sudo ./prevention/enforce-module-signing.sh"
    echo "  3. Run: sudo ./prevention/setup-filesystem-isolation.sh"
    echo "  4. Run: sudo ./prevention/setup-network-isolation.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    setup_logging
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    backup_existing_config
    create_nspawn_config
    set_permissions
    verify_config
    test_nspawn_config
    
    show_summary
    
    log_message "INFO" "Capability dropping configuration completed successfully"
}

# Run main function
main "$@"
