#!/usr/bin/env bash
# setup.sh - PROJ-MK-ULTRA Setup Wizard
# SUSPICIOUS Framework - Production Deployment
#
# Usage: sudo ./2_setup.sh

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/proj-mk-ultra/setup-$(date +%Y%m%d_%H%M%S).log"
STATE_FILE="/var/lib/proj-mk-ultra/setup-state"
BACKUP_DIR="/var/backups/proj-mk-ultra"

# shellcheck source=scripts/lib-hardware.sh
. "${SCRIPT_DIR}/scripts/lib-hardware.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Function to display banner
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║     ███╗   ███╗██╗   ██╗██████╗ ███████╗ ██████╗                             ║
║     ████╗ ████║██║   ██║██╔══██╗██╔════╝██╔═══██╗                            ║
║     ██╔████╔██║██║   ██║██████╔╝█████╗  ██║   ██║                            ║
║     ██║╚██╔╝██║██║   ██║██╔═══╝ ██╔══╝  ██║   ██║                            ║
║     ██║ ╚═╝ ██║╚██████╔╝██║     ███████╗╚██████╔╝                            ║
║     ╚═╝     ╚═╝ ╚═════╝ ╚═╝     ╚══════╝ ╚═════╝                             ║
║                                                                              ║
║     ███╗   ██╗██╗   ██╗██╗     ███╗   ███╗███████╗██████╗  █████╗ ██████╗    ║
║     ████╗  ██║██║   ██║██║     ████╗ ████║██╔════╝██╔══██╗██╔══██╗██╔══██╗   ║
║     ██╔██╗ ██║██║   ██║██║     ██╔████╔██║█████╗  ██████╔╝███████║██████╔╝   ║
║     ██║╚██╗██║██║   ██║██║     ██║╚██╔╝██║██╔══╝  ██╔══██╗██╔══██║██╔══██╗   ║
║     ██║ ╚████║╚██████╔╝███████╗██║ ╚═╝ ██║███████╗██║  ██║██║  ██║██║  ██║   ║
║     ╚═╝  ╚═══╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ║
║                                                                              ║
║     ████████╗███████╗██████╗ ███╗   ███╗██╗███╗   ██╗ █████╗ ██╗             ║
║     ╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║████╗  ██║██╔══██╗██║             ║
║        ██║   █████╗  ██████╔╝██╔████╔██║██║██╔██╗ ██║███████║██║             ║
║        ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║██║╚██╗██║██╔══██║██║             ║
║        ██║   ███████╗██║  ██║██║ ╚═╝ ██║██║██║ ╚████║██║  ██║███████╗        ║
║        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝        ║
║                                                                              ║
║                    PRODUCTION DEPLOYMENT WIZARD                              ║
║                    Version 1.0.0                                              ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Function to display step header
show_step() {
    local step_name="$1"
    local step_number="$2"
    local total_steps="$3"
    
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  Step ${step_number}/${total_steps}: ${step_name}${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════════════════════${NC}\n"
}

# Function to display status
show_status() {
    local status="$1"
    local message="$2"
    
    case "${status}" in
        OK)
            echo -e "  ${GREEN}✓${NC} ${message}"
            ;;
        WARN)
            echo -e "  ${YELLOW}⚠${NC} ${message}"
            ;;
        ERROR)
            echo -e "  ${RED}✗${NC} ${message}"
            ;;
        INFO)
            echo -e "  ${BLUE}→${NC} ${message}"
            ;;
        STEP)
            echo -e "  ${MAGENTA}▸${NC} ${message}"
            ;;
    esac
}

# Function to log messages
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}" >> "${LOG_FILE}"
}

# Function to prompt user
prompt_user() {
    local message="$1"
    local default="${2:-y}"
    
    if [ "${default}" = "y" ]; then
        echo -ne "${BOLD}${message} [Y/n]: ${NC}"
    else
        echo -ne "${BOLD}${message} [y/N]: ${NC}"
    fi
    
    if [ -t 0 ]; then
        read -r response
        response=${response:-${default}}
    else
        response="${default}"
        echo "(non-interactive: default '${default}')"
    fi
    
    [[ "${response}" =~ ^[Yy]$ ]]
}

# Function to prompt for input
prompt_input() {
    local message="$1"
    local default="${2:-}"
    
    if [ -n "${default}" ]; then
        echo -ne "${BOLD}${message} [${default}]: ${NC}"
    else
        echo -ne "${BOLD}${message}: ${NC}"
    fi
    
    if [ -t 0 ]; then
        read -r response
    else
        response=""
    fi
    echo "${response:-${default}}"
}

# Read one line into the named variable; on a non-TTY stdin take the default.
# A blocking read with no terminal (automation, systemd, pipes) hangs forever.
gate_read() {
    local __var="$1" __default="${2:-}" __line=""
    if [ -t 0 ]; then
        IFS= read -r __line || __line=""
    else
        echo "  (non-interactive: using default '${__default}')"
    fi
    printf -v "${__var}" '%s' "${__line:-${__default}}"
}

# Function to display progress bar
show_progress() {
    local current="$1"
    local total="$2"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r  ${BOLD}[${GREEN}"
    printf '█%.0s' $(seq 1 ${filled} 2>/dev/null) || true
    printf "${DIM}"
    printf '░%.0s' $(seq 1 ${empty} 2>/dev/null) || true
    printf "${NC}${BOLD}] ${percentage}%%${NC}"
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${BOLD}[ERROR] This script must be run as root${NC}"
        echo -e "${YELLOW}Please run: sudo ./2_setup.sh${NC}"
        exit 1
    fi
}

# Function to setup directories
setup_directories() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    mkdir -p "${STATE_FILE}"
    mkdir -p "${BACKUP_DIR}"
    touch "${LOG_FILE}"
}

# Function to detect distro
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID}"
    elif command -v lsb_release &> /dev/null; then
        lsb_release -is | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
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
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# ============================================================================
# PHASE FUNCTIONS
# ============================================================================

# Phase 1: System Detection
phase_system_detection() {
    show_step "System Detection & Compatibility" 1 8
    
    log_message "INFO" "Starting system detection"
    
    # Detect distro
    local distro
    distro=$(detect_distro)
    show_status "INFO" "Detected distribution: ${distro}"
    
    # Detect package manager
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    show_status "INFO" "Detected package manager: ${pkg_manager}"
    
    # Check architecture
    local arch
    arch=$(uname -m)
    if [ "${arch}" = "x86_64" ]; then
        show_status "OK" "Architecture: ${arch} (supported)"
    else
        show_status "ERROR" "Architecture: ${arch} (not supported - x86_64 required)"
        return 1
    fi
    
    # Check kernel version
    local kernel_version
    kernel_version=$(uname -r)
    show_status "INFO" "Kernel version: ${kernel_version}"
    
    # Check if multikernel is available
    # /proc/config.gz is gzip-compressed - requires zgrep (plain grep cannot read it)
    local multikernel_detected=false
    if zgrep -q "^CONFIG_MULTIKERNEL=y" /proc/config.gz 2>/dev/null; then
        multikernel_detected=true
    elif [ -d /sys/fs/multikernel ]; then
        multikernel_detected=true
    elif echo "${kernel_version}" | grep -iE "multikernel|mk2" > /dev/null; then
        multikernel_detected=true
    fi
    
    if [ "${multikernel_detected}" = "true" ]; then
        show_status "OK" "Multikernel support: Detected"
    else
        show_status "WARN" "Multikernel support: Not detected in current kernel"
        show_status "INFO" "Will verify during pre-installation checks"
    fi
    
    # Check available memory
    local mem_gb
    mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [ "${mem_gb}" -ge 16 ]; then
        show_status "OK" "Available memory: ${mem_gb}GB (recommended: 16GB+)"
    elif [ "${mem_gb}" -ge 8 ]; then
        show_status "WARN" "Available memory: ${mem_gb}GB (minimum: 8GB, recommended: 16GB+)"
    else
        show_status "ERROR" "Available memory: ${mem_gb}GB (minimum: 8GB required)"
        return 1
    fi
    
    # Check available disks
    local disk_count
    disk_count=$(lsblk -dno NAME 2>/dev/null | grep -cE "^(sd|vd|nvme)" || true)
    if [ "${disk_count}" -ge 2 ]; then
        show_status "OK" "Secondary disks: $((disk_count - 1)) available"
    else
        show_status "ERROR" "Secondary disks: None found (minimum: 1 required)"
        return 1
    fi
    
    # Check IOMMU support
    if dmesg 2>/dev/null | grep -- "IOMMU enabled" > /dev/null; then
        show_status "OK" "IOMMU: Enabled"
    elif [ -d /sys/kernel/iommu_groups ]; then
        show_status "OK" "IOMMU: Groups detected"
    else
        show_status "WARN" "IOMMU: Status unknown (will verify in prevention phase)"
    fi
    
    # Check IOMMU kernel parameter
    local iommu_param
    iommu_param=$(cat /proc/cmdline 2>/dev/null || echo "")
    if echo "${iommu_param}" | grep -E "intel_iommu=on|amd_iommu=on|iommu=pt" > /dev/null; then
        show_status "OK" "IOMMU kernel parameter: Detected"
    else
        show_status "WARN" "IOMMU kernel parameter: Not set (add intel_iommu=on or amd_iommu=on to kernel params)"
    fi
    
    # Check VFIO driver
    if lsmod 2>/dev/null | grep -- "vfio" > /dev/null; then
        show_status "OK" "VFIO driver: Loaded"
    else
        show_status "WARN" "VFIO driver: Not loaded (load with modprobe vfio-pci for device passthrough)"
    fi
    
    # Check systemd
    if pidof systemd >/dev/null 2>&1; then
        show_status "OK" "Init system: systemd"
    else
        show_status "ERROR" "Init system: Not systemd (required for SUSPICIOUS Framework)"
        return 1
    fi
    
    # Check cross-distro dependencies if enabled
    if [ "${CROSS_DISTRO_ENABLE:-false}" = "true" ]; then
        if command -v debootstrap &>/dev/null; then
            show_status "OK" "debootstrap: Installed"
        else
            show_status "WARN" "debootstrap: Not found (required for Debian/Ubuntu child rootfs)"
        fi
        if command -v dnf &>/dev/null; then
            show_status "OK" "dnf: Installed"
        else
            show_status "WARN" "dnf: Not found (required for Fedora/RHEL child rootfs)"
        fi
    fi
    
    # Save detection state
    echo "distro=${distro}" > "${STATE_FILE}/detection"
    echo "pkg_manager=${pkg_manager}" >> "${STATE_FILE}/detection"
    echo "arch=${arch}" >> "${STATE_FILE}/detection"
    
    log_message "INFO" "System detection complete: ${distro}, ${pkg_manager}, ${arch}"
    
    show_status "OK" "System detection complete"
    return 0
}

# Phase 2: Configuration
phase_configuration() {
	show_step "Configuration" 2 8
	
	log_message "INFO" "Starting configuration"
	
	# Load existing config or use defaults
	if [ -f "${SCRIPT_DIR}/etc/proj-mk-ultra.conf" ]; then
		show_status "INFO" "Loading existing configuration"
		source "${SCRIPT_DIR}/etc/proj-mk-ultra.conf"
	fi
	# Default keys the pre-F-048 conf generation never wrote - without this,
	# the Phase-8 fidelity loop dies on ${!key} (set -u, unbound variable).
	SPAWN_KEEP_BOUND="${SPAWN_KEEP_BOUND:-true}"
	
	# Only 5 human gates — everything else reads from conf silently.
	# The human reviews the conf before running. This wizard confirms.
	
	# Gate 1: Security level
	echo -ne "${BOLD}Security level (basic/intermediate/advanced) [${SECURITY_LEVEL:-basic}]: ${NC}"
	gate_read security_choice "${SECURITY_LEVEL:-basic}"
	SECURITY_LEVEL="${security_choice}"
	show_status "OK" "Security level: ${SECURITY_LEVEL}"
	
	# Gate 2: Child memory (movablecore math)
	echo -ne "${BOLD}Child memory [${CHILD_MEMORY_SIZE:-112G}]: ${NC}"
	gate_read mem_input "${CHILD_MEMORY_SIZE:-112G}"
	CHILD_MEMORY_SIZE="${mem_input}"
	# Compute the zone size here (rounded UP so the value shown below and the
	# value synced to the boot entry later are identical): child + 36G slack.
	MOVABLECORE="${MOVABLECORE:-$(( ($(size_to_bytes "${CHILD_MEMORY_SIZE}") + 1073741823) / 1073741824 + 36 ))}"
	MOVABLECORE="${MOVABLECORE%G}G"
	
	# Gate 3: CPU mask
	echo -ne "${BOLD}Child CPU mask [${CHILD_CPU_MASK:-0xFFFFFFF0}]: ${NC}"
	gate_read mask_input "${CHILD_CPU_MASK:-0xFFFFFFF0}"
	CHILD_CPU_MASK="${mask_input}"
	
	# Gate 4: PCI devices
	echo -ne "${BOLD}PCI devices passed to child [${PASSTHROUGH_PCI_DEVICES:-01:00.0}]: ${NC}"
	gate_read pci_input "${PASSTHROUGH_PCI_DEVICES:-01:00.0}"
	PASSTHROUGH_PCI_DEVICES="${pci_input}"
	
	# Gate 5: Target disk
	echo -ne "${BOLD}Target disk [${TARGET_DISK:-sdb}]: ${NC}"
	gate_read disk_input "${TARGET_DISK:-sdb}"
	TARGET_DISK="${disk_input}"
	
	show_status "OK" "Child: ${CHILD_MEMORY_SIZE} RAM, CPU mask ${CHILD_CPU_MASK}, PCI ${PASSTHROUGH_PCI_DEVICES}"
	show_status "INFO" "Boot param: movablecore=${MOVABLECORE} (child + 36G scan slack)"
	
	# Everything else reads from conf silently — no prompts
	show_status "INFO" "Filesystem: ${CORE_HOST_FILESYSTEM} (from conf)"
	show_status "INFO" "Leapfrog: ${CHILD_LEAPFROG_FS_ENABLE} (from conf)"
	show_status "INFO" "Cross-distro: ${CROSS_DISTRO_ENABLE} (from conf)"
	show_status "INFO" "Install target: ${INSTALL_TARGET} (from conf)"
	
	# Save configuration
	show_status "STEP" "Saving configuration..."
	
	mkdir -p "${SCRIPT_DIR}/etc"
	cat > "${SCRIPT_DIR}/etc/proj-mk-ultra.conf" << EOF
# PROJ-MK-ULTRA Configuration
# Generated by setup.sh on $(date)
# Keys MUST be valid bash variable names (UPPERCASE_UNDERSCORE).

# Host Configuration
CORE_HOST_FILESYSTEM="${CORE_HOST_FILESYSTEM}"
SECURITY_LEVEL="${SECURITY_LEVEL}"

# Leapfrog Filesystem Diversity
CHILD_LEAPFROG_FS_ENABLE="${CHILD_LEAPFROG_FS_ENABLE:-false}"
CHILD_LEAPFROG_FS="${CHILD_LEAPFROG_FS:-btrfs}"
CHILD_LEAPFROG_ALT="${CHILD_LEAPFROG_ALT:-xfs}"

# Cross-Distro Support
CROSS_DISTRO_ENABLE="${CROSS_DISTRO_ENABLE:-false}"
CHILD_DISTRO="${CHILD_DISTRO:-arch}"

# Installation Target
INSTALL_TARGET="${INSTALL_TARGET}"

# Child Kernel Configuration
CHILD_ROOT_SIZE="${CHILD_ROOT_SIZE:-20G}"
CHILD_BOOT_SIZE="${CHILD_BOOT_SIZE:-512M}"
CHILD_DATA_SIZE="${CHILD_DATA_SIZE:-100%}"

# Child Instance Hardware Assignment
CHILD_CPU_MASK="${CHILD_CPU_MASK:-0xFFFFFFF0}"
CHILD_MEMORY_SIZE="${CHILD_MEMORY_SIZE:-112G}"
PASSTHROUGH_PCI_DEVICES="${PASSTHROUGH_PCI_DEVICES:-01:00.0}"
MOVABLECORE="${MOVABLECORE}"
SPAWN_KEEP_BOUND="${SPAWN_KEEP_BOUND:-true}"
MEMORY_RESERVATION_ACKNOWLEDGED="${MEMORY_RESERVATION_ACKNOWLEDGED:-false}"
CHILD_KERNEL_PATH="${CHILD_KERNEL_PATH:-}"
CHILD_INITRD_PATH="${CHILD_INITRD_PATH:-}"

# Security Settings
MODULE_SIGNING_ENFORCE="${MODULE_SIGNING_ENFORCE:-true}"
IOMMU_VERIFY="${IOMMU_VERIFY:-true}"
CAPABILITY_DROPPING="${CAPABILITY_DROPPING:-true}"
FILESYSTEM_ISOLATION="${FILESYSTEM_ISOLATION:-true}"
NETWORK_ISOLATION="${NETWORK_ISOLATION:-true}"

# Detection Settings
BOOT_INTEGRITY_MONITOR="${BOOT_INTEGRITY_MONITOR:-true}"
HARDWARE_ISOLATION_MONITOR="${HARDWARE_ISOLATION_MONITOR:-true}"
SYSFS_ACCESS_MONITOR="${SYSFS_ACCESS_MONITOR:-true}"
MODULE_LOADING_MONITOR="${MODULE_LOADING_MONITOR:-true}"
BEHAVIORAL_ANOMALY_DETECTION="${BEHAVIORAL_ANOMALY_DETECTION:-true}"

# Response Settings
AUTO_DESTROY_ON_DETECTION="${AUTO_DESTROY_ON_DETECTION:-true}"
PRESERVE_USER_DATA="${PRESERVE_USER_DATA:-true}"
FORENSIC_LOGGING="${FORENSIC_LOGGING:-true}"
RECOVERY_PROCEDURES="${RECOVERY_PROCEDURES:-true}"

# Update Settings
AUTO_UPDATE_MAINSTREAM="${AUTO_UPDATE_MAINSTREAM:-false}"
AUTO_UPDATE_MULTIKERNEL="${AUTO_UPDATE_MULTIKERNEL:-false}"
AUTO_SYNC_CHILD="${AUTO_SYNC_CHILD:-false}"

# Btrfs Snapshot Settings
BTRFS_SNAPSHOT_ENABLE="${BTRFS_SNAPSHOT_ENABLE:-false}"
BTRFS_SNAPSHOT_KEEP="${BTRFS_SNAPSHOT_KEEP:-5}"

# Disk Configuration
TARGET_DISK="${TARGET_DISK:-}"
CHILD_BOOT_DEVICE="${CHILD_BOOT_DEVICE:-}"
CHILD_ROOT_DEVICE="${CHILD_ROOT_DEVICE:-}"
CHILD_DATA_DEVICE="${CHILD_DATA_DEVICE:-}"
EOF
	
	show_status "OK" "Configuration saved to ${SCRIPT_DIR}/etc/proj-mk-ultra.conf"
	
	# Sync the mk boot entry's movablecore from the conf - the operator never
	
	# hand-edits the options line for this parameter again.
	
	MOVABLECORE="${MOVABLECORE:-$(( ($(size_to_bytes "${CHILD_MEMORY_SIZE:-112G}") + 1073741823) / 1073741824 + 36 ))}"
	MOVABLECORE="${MOVABLECORE%G}G"
	
	local entry_file
	
	entry_file=$(grep -rl "multikernel\|mk2" /boot/loader/entries/ 2>/dev/null | head -1 || true)
	
	if [ -n "${entry_file}" ]; then
	    if grep -q "movablecore=" "${entry_file}"; then
	        sed -i "s/movablecore=[0-9]*G*/movablecore=${MOVABLECORE}/" "${entry_file}"
	    elif grep -q "^options " "${entry_file}"; then
	        # mkinitcpio regenerates BLS entries from /etc/kernel/cmdline and
	        # silently drops movablecore - append it back (sanctioned change).
	        sed -i "s/^options \(.*\)$/options \1 movablecore=${MOVABLECORE}/" "${entry_file}"
	    fi
	elif [ -f /etc/default/grub ]; then
	    entry_file="/etc/default/grub"
	    if grep -q "GRUB_CMDLINE_LINUX_DEFAULT=.*movablecore=" "${entry_file}"; then
	        sed -i "s/\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)movablecore=[^\" ]*\([^\"]*\"\)/\1movablecore=${MOVABLECORE}\2/" "${entry_file}"
	    else
	        sed -i "s/\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"/\1 movablecore=${MOVABLECORE}\"/" "${entry_file}"
	    fi
	    if command -v update-grub > /dev/null; then
	        update-grub > /dev/null 2>&1 || true
	    elif command -v grub-mkconfig > /dev/null; then
	        grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1 || true
	    fi
	fi
	
	if [ -f /etc/kernel/cmdline ]; then
	    if grep -q "movablecore=" /etc/kernel/cmdline; then
	        sed -i "s/movablecore=[0-9]*G*/movablecore=${MOVABLECORE}/" /etc/kernel/cmdline
	    else
	        sed -i "s/$/ movablecore=${MOVABLECORE}/" /etc/kernel/cmdline
	    fi
	    show_status "OK" "Appended movablecore=${MOVABLECORE} to /etc/kernel/cmdline to survive mkinitcpio"
	fi
	
	if [ -n "${entry_file}" ] && grep -q "movablecore=${MOVABLECORE}" "${entry_file}"; then
	
	    show_status "OK" "Boot entry synced: ${entry_file##*/} → movablecore=${MOVABLECORE}"
	
	    # Sanctioned change: refresh the boot-integrity baselines so the
	
	    # operator's own edit is the new legitimate state (a rogue edit still
	
	    # triggers - it will not match these refreshed baselines).
	
	    local new_hash
	
	    new_hash=$(cat /boot/loader/entries/*.conf 2>/dev/null | sha256sum | cut -d' ' -f1)
	
	    if [ -n "${new_hash}" ]; then
	
	        mkdir -p /var/lib/proj-mk-ultra/watch /var/lib/proj-mk-ultra/monitoring
	
	        echo "${new_hash}" > /var/lib/proj-mk-ultra/watch/boot-hashes.sha256
	
	        echo "${new_hash}" > /var/lib/proj-mk-ultra/monitoring/boot-hashes.sha256
	
	        show_status "OK" "Boot-integrity baselines refreshed (sanctioned change)"
	
	    fi
	
	else
	
	    show_status "WARN" "movablecore=${MOVABLECORE} could not be synced into the mk boot entry (missing entry or no options line) - set it manually, then reboot"
	
	fi
	
	log_message "INFO" "Configuration complete: level=${SECURITY_LEVEL}, host_fs=${CORE_HOST_FILESYSTEM}"
	
	show_status "OK" "Configuration complete"
	return 0
}

phase_pre_installation() {
    show_step "Pre-installation Checks" 3 8
    
    log_message "INFO" "Starting pre-installation checks"
    
    # Verify child memory reservation (read-only advisory - boot entries stay manual)
    local movable_bytes
    movable_bytes=$(movable_zone_bytes)
    local child_bytes
    child_bytes=$(size_to_bytes "${CHILD_MEMORY_SIZE:-112G}")
    if [ "${movable_bytes}" -ge "${child_bytes}" ]; then
        show_status "OK" "Child memory reservation: ZONE_MOVABLE $(( movable_bytes / 1073741824 ))GB >= child ${CHILD_MEMORY_SIZE:-112G}"
    else
        show_status "WARN" "ZONE_MOVABLE short ($(( movable_bytes / 1073741824 ))GB < ${CHILD_MEMORY_SIZE:-112G}) - child memory NOT reserved yet"
        show_status "INFO" "Add to the multikernel entry options line, then reboot BEFORE spawning:"
        show_status "INFO" "  movablecore=${CHILD_MEMORY_SIZE:-112G}"
    fi
    
    # Mount multikernel sysfs if not yet mounted
    if ! mountpoint -q /sys/fs/multikernel 2>/dev/null; then
        mkdir -p /sys/fs/multikernel 2>/dev/null || true
        if mount -t multikernel none /sys/fs/multikernel 2>/dev/null; then
            show_status "OK" "Multikernel sysfs mounted"
        else
            show_status "WARN" "Multikernel sysfs not mountable (expected on non-multikernel kernel)"
        fi
    else
        show_status "OK" "Multikernel sysfs available"
    fi

    # Boot-time baseline: install mk-baseline.service so the pool boundary
    # is established before the desktop session on every boot (idempotent).
    # Only on a running multikernel kernel - fresh machines get it on the
    # next wizard run after the pre-install reboot.
    if mountpoint -q /sys/fs/multikernel && [ -f "${SCRIPT_DIR}/scripts/apply-baseline.sh" ]; then
        show_status "STEP" "Installing baseline service (mk-baseline)"
        cat > /etc/systemd/system/mk-baseline.service << EOUNIT
[Unit]
Description=PROJ-MK-ULTRA multikernel baseline (pool boundary establishment)
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target
Before=multi-user.target
ConditionKernelCommandLine=|movablecore
ConditionPathExists=${SCRIPT_DIR}/scripts/apply-baseline.sh

[Service]
Type=oneshot
ExecStart=/usr/bin/bash ${SCRIPT_DIR}/scripts/apply-baseline.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOUNIT
        systemctl daemon-reload
        if systemctl enable mk-baseline.service > /dev/null 2>&1; then
            show_status "OK" "Baseline service installed and ENABLED: /etc/systemd/system/mk-baseline.service"
            show_status "INFO" "mk-baseline runs at next boot BEFORE the user session - this is required for reliable pool allocation"
        else
            show_status "WARN" "Baseline service installed but 'systemctl enable' failed - run manually:"
            show_status "INFO" "  sudo systemctl enable mk-baseline.service && sudo systemctl daemon-reload"
        fi
        # Verify the enable actually stuck
        if ! systemctl is-enabled --quiet mk-baseline.service 2>/dev/null; then
            show_status "WARN" "mk-baseline.service is NOT enabled - pool will only apply on-demand (fragmentation risk)"
            show_status "INFO" "Manual fix: sudo systemctl enable mk-baseline.service"
        fi

        # Operator control channel: while the child owns USB (keyboard/mouse),
        # host control rides SSH on the NIC - the NIC never leaves the host.
        if command -v sshd >/dev/null 2>&1 || pacman -Q openssh >/dev/null 2>&1 || \
           dpkg -s openssh-server >/dev/null 2>&1; then
            systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
            show_status "OK" "Host SSH active (operator channel while child owns USB)"
        else
            show_status "WARN" "openssh not installed - host SSH unavailable while child owns USB"
        fi
        show_status "INFO" "Pool applies at next boot (pre-session); spawn falls back to on-demand baseline"
    fi
    
    # Check multikernel - if absent, OFFER the automated pre-install instead
    # of failing (a fresh machine is a normal entry point, not an error)
    show_status "STEP" "Checking multikernel support..."
    if bash "${SCRIPT_DIR}/pre-install/check-multikernel.sh"; then
        show_status "OK" "Multikernel support verified"
    else
        show_status "WARN" "Multikernel kernel not installed on this machine"
        echo -ne "${BOLD}Run the automated pre-install now? (builds kernel from pinned source, ~10-40 min) [y/N]: ${NC}"
        gate_read preinstall_choice "n"
        if [ "${preinstall_choice}" = "y" ] || [ "${preinstall_choice}" = "Y" ]; then
            if bash "${SCRIPT_DIR}/1_pre-install.sh"; then
                show_status "OK" "Pre-install complete - REBOOT into the new kernel, verify (uname -r / zoneinfo movable / taint=0), then re-run this wizard"
            else
                show_status "ERROR" "Pre-install failed - review output above, fix, re-run"
            fi
        fi
        return 1
    fi
    
    # Check disks
    show_status "STEP" "Checking disk configuration..."
    if bash "${SCRIPT_DIR}/pre-install/check-disks.sh"; then
        show_status "OK" "Disk configuration verified"
    else
        show_status "ERROR" "Disk configuration check failed"
        return 1
    fi
    
    # Partition disk (with user confirmation). A disk that already carries
    # filesystems is a prior deployment - destructive default is forbidden
    # there; the default flips to no and partition-disk.sh adds its own
    # explicit WIPE gate.
    show_status "STEP" "Partitioning secondary disk..."
    local deployed=0
    if blkid "/dev/${TARGET_DISK}1" >/dev/null 2>&1 || \
       blkid "/dev/${TARGET_DISK}2" >/dev/null 2>&1 || \
       blkid "/dev/${TARGET_DISK}3" >/dev/null 2>&1; then
        deployed=1
        show_status "WARN" "Existing deployment detected on /dev/${TARGET_DISK} - partitioning will DESTROY it"
    fi
    local pdefault="y"
    [ "${deployed}" = "1" ] && pdefault="n"
    if prompt_user "Do you want to partition the secondary disk now?" "${pdefault}"; then
        if bash "${SCRIPT_DIR}/pre-install/partition-disk.sh"; then
            show_status "OK" "Disk partitioning complete"
        else
            show_status "ERROR" "Disk partitioning failed"
            return 1
        fi
    else
        show_status "INFO" "Skipping disk partitioning (can run later)"
    fi
    
    # Install child kernel (with user confirmation)
    show_status "STEP" "Installing child kernel..."
    if prompt_user "Do you want to install the child kernel now?" "y"; then
        if bash "${SCRIPT_DIR}/pre-install/install-child-kernel.sh"; then
            show_status "OK" "Child kernel installed"
        else
            show_status "ERROR" "Child kernel installation failed"
            return 1
        fi
    else
        show_status "INFO" "Skipping child kernel installation (can run later)"
    fi
    
    # Setup updates
    show_status "STEP" "Configuring update system..."
    if bash "${SCRIPT_DIR}/pre-install/setup-updates.sh"; then
        show_status "OK" "Update system configured"
    else
        show_status "WARN" "Update system configuration had warnings"
    fi
    
    log_message "INFO" "Pre-installation checks complete"
    
    show_status "OK" "Pre-installation complete"
    return 0
}

# Phase 3: Prevention Layer
phase_prevention_layer() {
    show_step "Prevention Layer Configuration" 4 8
    
    log_message "INFO" "Configuring prevention layer"
    
    # Verify IOMMU - hardware isolation is load-bearing: failure ABORTS the
    # deployment (a host without IOMMU cannot honor any framework invariant)
    show_status "STEP" "Verifying IOMMU configuration..."
    if bash "${SCRIPT_DIR}/prevention/verify-iommu.sh"; then
        show_status "OK" "IOMMU verification complete"
    else
        show_status "ERROR" "IOMMU verification FAILED - hardware isolation is mandatory"
        return 1
    fi
    
    # Enforce module signing
    show_status "STEP" "Enforcing module signing..."
    if bash "${SCRIPT_DIR}/prevention/enforce-module-signing.sh"; then
        show_status "OK" "Module signing enforced"
    else
        show_status "WARN" "Module signing enforcement had warnings"
    fi
    
    # Setup capability dropping
    show_status "STEP" "Configuring capability dropping..."
    if bash "${SCRIPT_DIR}/prevention/setup-capability-dropping.sh"; then
        show_status "OK" "Capability dropping configured"
    else
        show_status "WARN" "Capability dropping configuration had warnings"
    fi
    
    # Setup filesystem isolation
    show_status "STEP" "Configuring filesystem isolation..."
    if bash "${SCRIPT_DIR}/prevention/setup-filesystem-isolation.sh"; then
        show_status "OK" "Filesystem isolation configured"
    else
        show_status "WARN" "Filesystem isolation configuration had warnings"
    fi
    
    # Setup network isolation
    show_status "STEP" "Configuring network isolation..."
    if bash "${SCRIPT_DIR}/prevention/setup-network-isolation.sh"; then
        show_status "OK" "Network isolation configured"
    else
        show_status "WARN" "Network isolation configuration had warnings"
    fi
    
    log_message "INFO" "Prevention layer configuration complete"
    
    show_status "OK" "Prevention layer configured"
    return 0
}

# Phase 4: Detection Layer
phase_detection_layer() {
    show_step "Detection Layer Setup" 5 8
    
    log_message "INFO" "Setting up detection layer"
    
    # Monitor boot integrity
    show_status "STEP" "Setting up boot integrity monitoring..."
    if bash "${SCRIPT_DIR}/detection/monitor-boot-integrity.sh" --install; then
        show_status "OK" "Boot integrity monitoring installed"
    else
        show_status "WARN" "Boot integrity monitoring had warnings"
    fi
    
    # Monitor hardware isolation
    show_status "STEP" "Setting up hardware isolation monitoring..."
    if bash "${SCRIPT_DIR}/detection/monitor-hardware-isolation.sh" --install; then
        show_status "OK" "Hardware isolation monitoring installed"
    else
        show_status "WARN" "Hardware isolation monitoring had warnings"
    fi
    
    # Monitor sysfs access
    show_status "STEP" "Setting up sysfs access monitoring..."
    if bash "${SCRIPT_DIR}/detection/monitor-sysfs-access.sh" --install; then
        show_status "OK" "Sysfs access monitoring installed"
    else
        show_status "WARN" "Sysfs access monitoring had warnings"
    fi
    
    # Monitor module loading
    show_status "STEP" "Setting up module loading monitoring..."
    if bash "${SCRIPT_DIR}/detection/monitor-module-loading.sh" --install; then
        show_status "OK" "Module loading monitoring installed"
    else
        show_status "WARN" "Module loading monitoring had warnings"
    fi
    
    # Monitor behavioral anomalies
    show_status "STEP" "Setting up behavioral anomaly detection..."
    if bash "${SCRIPT_DIR}/detection/monitor-behavioral-anomalies.sh" --install; then
        show_status "OK" "Behavioral anomaly detection installed"
    else
        show_status "WARN" "Behavioral anomaly detection had warnings"
    fi
    
    # Resident watcher (FSV-5 end-to-end): continuous taint/boot-hash/instance
    # watch at 1% CPU / 64M ceiling - installed and activated here so the
    # watcher log exists before FSV ever runs.
    show_status "STEP" "Installing resident watcher (suspicious-watch)..."
    cat > /etc/systemd/system/suspicious-watch.service << EOUNIT
[Unit]
Description=SUSPICIOUS Resident Anomaly Watcher
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/bash ${SCRIPT_DIR}/detection/resident-watch.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
CPUQuota=1%
MemoryMax=64M
MemoryHigh=32M
IOWeight=10

[Install]
WantedBy=multi-user.target
EOUNIT
    systemctl daemon-reload
    systemctl enable --now suspicious-watch.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet suspicious-watch.service; then
        show_status "OK" "Resident watcher active (CPUQuota=1%, MemoryMax=64M)"
    else
        show_status "WARN" "Watcher installed but not active - check: systemctl status suspicious-watch"
    fi

    log_message "INFO" "Detection layer setup complete"
    
    show_status "OK" "Detection layer configured"
    return 0
}

# Phase 5: Response Layer
phase_response_layer() {
    show_step "Response Layer Configuration" 6 8
    
    log_message "INFO" "Configuring response layer"
    
    # Configure auto-destroy
    show_status "STEP" "Configuring auto-destroy on detection..."
    if bash "${SCRIPT_DIR}/response/auto-destroy.sh" --install; then
        show_status "OK" "Auto-destroy configured"
    else
        show_status "WARN" "Auto-destroy configuration had warnings"
    fi
    
    # Configure data preservation
    show_status "STEP" "Configuring data preservation..."
    if bash "${SCRIPT_DIR}/response/preserve-data.sh" --install; then
        show_status "OK" "Data preservation configured"
    else
        show_status "WARN" "Data preservation configuration had warnings"
    fi
    
    # Configure forensic logging
    show_status "STEP" "Configuring forensic logging..."
    if bash "${SCRIPT_DIR}/response/forensic-logging.sh" --install; then
        show_status "OK" "Forensic logging configured"
    else
        show_status "WARN" "Forensic logging configuration had warnings"
    fi
    
    # Configure recovery
    show_status "STEP" "Configuring recovery procedures..."
    if bash "${SCRIPT_DIR}/response/recovery.sh" --install; then
        show_status "OK" "Recovery procedures configured"
    else
        show_status "WARN" "Recovery procedures configuration had warnings"
    fi
    
    log_message "INFO" "Response layer configuration complete"
    
    show_status "OK" "Response layer configured"
    return 0
}

# Phase 6: Update System
phase_update_system() {
    show_step "Update System Setup" 7 8
    
    log_message "INFO" "Setting up update system"
    
    # Configure mainstream updates
    show_status "STEP" "Configuring mainstream kernel updates..."
    if bash "${SCRIPT_DIR}/update/update-mainstream.sh" --install; then
        show_status "OK" "Mainstream update system configured"
    else
        show_status "WARN" "Mainstream update system configuration had warnings"
    fi
    
    # Configure multikernel updates
    show_status "STEP" "Configuring multikernel updates..."
    if bash "${SCRIPT_DIR}/update/update-multikernel.sh" --install; then
        show_status "OK" "Multikernel update system configured"
    else
        show_status "WARN" "Multikernel update system configuration had warnings"
    fi
    
    # Configure child kernel sync
    show_status "STEP" "Configuring child kernel sync..."
    if bash "${SCRIPT_DIR}/update/sync-child-kernel.sh" --install; then
        show_status "OK" "Child kernel sync configured"
    else
        show_status "WARN" "Child kernel sync configuration had warnings"
    fi
    
    log_message "INFO" "Update system setup complete"
    
    show_status "OK" "Update system configured"
    return 0
}

# Phase 7: Final Verification
phase_final_verification() {
    show_step "Final Verification & Summary" 8 8
    
    log_message "INFO" "Running final verification"
    
    # Verify installation
    show_status "STEP" "Verifying installation..."
    
    local errors=0
    
    # Check all directories exist
    for dir in pre-install prevention detection response update; do
        if [ -d "${SCRIPT_DIR}/${dir}" ]; then
            show_status "OK" "Directory: ${dir}"
        else
            show_status "ERROR" "Directory missing: ${dir}"
            errors=$((errors + 1))
        fi
    done
    
    # Check critical scripts exist
    local critical_scripts=(
        "pre-install/check-multikernel.sh"
        "pre-install/check-disks.sh"
        "pre-install/partition-disk.sh"
        "pre-install/install-child-kernel.sh"
        "pre-install/setup-updates.sh"
        "prevention/verify-iommu.sh"
        "prevention/enforce-module-signing.sh"
        "prevention/setup-capability-dropping.sh"
        "prevention/setup-filesystem-isolation.sh"
        "prevention/setup-network-isolation.sh"
        "detection/monitor-boot-integrity.sh"
        "detection/monitor-hardware-isolation.sh"
        "detection/monitor-sysfs-access.sh"
        "detection/monitor-module-loading.sh"
        "detection/monitor-behavioral-anomalies.sh"
        "response/auto-destroy.sh"
        "response/preserve-data.sh"
        "response/forensic-logging.sh"
        "response/recovery.sh"
        "update/update-mainstream.sh"
        "update/update-multikernel.sh"
        "update/sync-child-kernel.sh"
    )
    
    for script in "${critical_scripts[@]}"; do
        if [ -x "${SCRIPT_DIR}/${script}" ]; then
            show_status "OK" "Script: ${script}"
        else
            show_status "ERROR" "Script missing or not executable: ${script}"
            errors=$((errors + 1))
        fi
    done
    
    # Check log file
    if [ -f "${LOG_FILE}" ]; then
        show_status "OK" "Log file: ${LOG_FILE}"
    else
        show_status "WARN" "Log file not created"
    fi
    
    # Check state file
    if [ -f "${STATE_FILE}/detection" ]; then
        show_status "OK" "State file: ${STATE_FILE}/detection"
    else
        show_status "WARN" "State file not created"
    fi
    
    # Verify config completeness AND value fidelity: the saved file must
    # match what the wizard actually selected (the in-memory values)
    local sem_mismatch=0
    local key saved_val expected_val
    for key in CORE_HOST_FILESYSTEM SECURITY_LEVEL CHILD_LEAPFROG_FS_ENABLE CHILD_LEAPFROG_FS CHILD_LEAPFROG_ALT CROSS_DISTRO_ENABLE CHILD_DISTRO INSTALL_TARGET CHILD_ROOT_SIZE CHILD_BOOT_SIZE CHILD_DATA_SIZE CHILD_CPU_MASK CHILD_MEMORY_SIZE PASSTHROUGH_PCI_DEVICES MOVABLECORE SPAWN_KEEP_BOUND BTRFS_SNAPSHOT_ENABLE BTRFS_SNAPSHOT_KEEP; do
        saved_val=$(grep "^${key}=" "${SCRIPT_DIR}/etc/proj-mk-ultra.conf" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"')
        expected_val="${!key}"
        if [ -z "${saved_val}" ]; then
            show_status "ERROR" "Config key missing/empty: ${key}"
            sem_mismatch=$((sem_mismatch + 1))
        elif [ "${saved_val}" != "${expected_val}" ]; then
            show_status "ERROR" "Config drift: ${key} saved='${saved_val}' wizard='${expected_val}'"
            sem_mismatch=$((sem_mismatch + 1))
        fi
    done
    if [ "${sem_mismatch}" -eq 0 ]; then
        show_status "OK" "Config fidelity: saved values match wizard selections"
    else
        show_status "ERROR" "${sem_mismatch} config keys missing or drifted from wizard selections"
        errors=$((errors + 1))
    fi

    # Verify spawn path is executable
    if [ -x "${SCRIPT_DIR}/scripts/spawn-child-instance.sh" ]; then
        show_status "OK" "Spawn path: scripts/spawn-child-instance.sh"
    else
        show_status "ERROR" "Spawn path missing or not executable: scripts/spawn-child-instance.sh"
        errors=$((errors + 1))
    fi
    
    echo
    
    if [ ${errors} -eq 0 ]; then
        show_status "OK" "All verification checks passed"
    else
        show_status "ERROR" "${errors} verification checks failed"
        return 1
    fi
    
    # Display summary
    echo -e "\n${BOLD}${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  INSTALLATION COMPLETE${NC}"
    echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${BOLD}PROJ-MK-ULTRA has been successfully installed!${NC}\n"
    
    echo -e "${BOLD}What was installed:${NC}"
    echo -e "  ✓ Pre-installation system (5 scripts)"
    echo -e "  ✓ Prevention layer (5 scripts)"
    echo -e "  ✓ Detection layer (5 scripts)"
    echo -e "  ✓ Response layer (4 scripts)"
    echo -e "  ✓ Update system (3 scripts)"
    echo
    
    echo -e "${BOLD}Next Steps (launch-pad model — NO REBOOT):${NC}"
    echo -e "  1. Insert SD/secondary disk and confirm device name: lsblk"
    echo -e "  2. Pre-spawn baseline: sudo ${SCRIPT_DIR}/scripts/first-spawn-validate.sh --pre-spawn"
    echo -e "  3. Spawn the child kernel: sudo ${SCRIPT_DIR}/scripts/spawn-child-instance.sh child-fsv"
    echo -e "  4. Validate: sudo ${SCRIPT_DIR}/scripts/first-spawn-validate.sh"
    echo -e "  5. FSV report is the finish line — paste on FAIL/REVIEW"
    echo
    
    echo -e "${BOLD}Important Files:${NC}"
    echo -e "  Installation log: ${LOG_FILE}"
    echo -e "  Documentation: ${SCRIPT_DIR}/docs/"
    echo -e "  Filesystem guide: ${SCRIPT_DIR}/docs/filesystem-guide.md"
    echo -e "  Cross-distro guide: ${SCRIPT_DIR}/docs/cross-distro-guide.md"
    echo
    
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  sudo ${SCRIPT_DIR}/scripts/security-audit.sh    # Run security audit"
    echo -e "  sudo ${SCRIPT_DIR}/scripts/system-monitor.sh   # Monitor system"
    echo -e "  sudo ${SCRIPT_DIR}/scripts/suspicious-boot.sh  # Boot selector"
    echo
    
    log_message "INFO" "Installation complete"
    
    return 0
}

# ============================================================================
# MAIN FUNCTION
# ============================================================================

main() {
    # Check root
    check_root
    
    # Setup directories
    setup_directories
    
    # Show banner
    show_banner
    
    # Display system info
    echo -e "${BOLD}System Information:${NC}"
    echo -e "  Host: $(hostname)"
    echo -e "  Date: $(date)"
    echo -e "  User: $(whoami)"
    echo
    
    # Prompt to continue
    if ! prompt_user "Ready to begin PROJ-MK-ULTRA installation?" "y"; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        exit 0
    fi
    
    # Run phases
    local phases=(
        "phase_system_detection"
        "phase_configuration"
        "phase_pre_installation"
        "phase_prevention_layer"
        "phase_detection_layer"
        "phase_response_layer"
        "phase_update_system"
        "phase_final_verification"
    )
    
    local total_phases=${#phases[@]}
    local current_phase=0
    
    for phase in "${phases[@]}"; do
        current_phase=$((current_phase + 1))
        
        if ! ${phase}; then
            echo -e "\n${RED}${BOLD}[ERROR] Phase ${current_phase}/${total_phases} failed${NC}"
            echo -e "${YELLOW}Check log file for details: ${LOG_FILE}${NC}"
            exit 1
        fi
        
        show_progress ${current_phase} ${total_phases}
        echo
    done
    
    echo -e "\n${GREEN}${BOLD}Installation completed successfully!${NC}"
    if systemctl is-enabled --quiet mk-baseline.service 2>/dev/null; then
        echo -e "${YELLOW}REBOOT ONCE to establish the pool boundary pre-session${NC}"
        echo -e "${YELLOW}(mk-baseline.service applies it at boot; every later spawn is launch-pad, no reboot)${NC}"
    else
        echo -e "${YELLOW}Launch-pad model: no reboot needed - spawn when ready.${NC}"
    fi
}

# Run main function
main "$@"
