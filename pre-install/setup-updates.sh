#!/usr/bin/env bash
# setup-updates.sh - Configure automatic updates for child kernel
# SUSPICIOUS Framework: Pre-Installation
#
# Sets up:
# - Automatic update checking
# - Update installation for mainstream kernel
# - Update installation for multikernel kernel
# - Sync updates to child kernel
#
# Usage: sudo ./setup-updates.sh

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
UPDATE_DIR="/opt/suspicious/updates"
LOG_FILE="/var/log/suspicious-updates.log"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         UPDATE SYSTEM SETUP                                        ║
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

# Function to create update directories
create_update_directories() {
    show_step "Creating Update Directories" 2
    
    local directories=(
        "${UPDATE_DIR}"
        "${UPDATE_DIR}/mainstream"
        "${UPDATE_DIR}/multikernel"
        "${UPDATE_DIR}/child"
        "${UPDATE_DIR}/logs"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "${dir}"
        show_status "OK" "Created: ${dir}"
    done
}

# Function to create update script
create_update_script() {
    show_step "Creating Update Script" 3
    
    cat > "${UPDATE_DIR}/update.sh" << 'EOF'
#!/usr/bin/env bash
# update.sh - Update system for SUSPICIOUS Framework
# This script is called by the update service

set -euo pipefail

# Configuration
UPDATE_DIR="/opt/suspicious/updates"
LOG_FILE="/var/log/suspicious-updates.log"
HOST_ROOT="/"
CHILD_ROOT="/mnt/child-root"

# Logging function
log_event() {
    local event="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $event" >> "${LOG_FILE}"
    logger -t suspicious-updates "$level: $event"
}

# Config discovery: system install path, then baked repo path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${PROJ_MK_ULTRA_CONFIG:-/etc/proj-mk-ultra/proj-mk-ultra.conf}"
[ -f "${CONFIG_FILE}" ] || CONFIG_FILE="REPO_CONFIG_PLACEHOLDER"
[ -f "${CONFIG_FILE}" ] && . "${CONFIG_FILE}"

# Function to update mainstream kernel
update_mainstream() {
    if [ "${AUTO_UPDATE_MAINSTREAM:-false}" != "true" ]; then
        log_event "Mainstream update skipped - disabled by config" "INFO"
        return 0
    fi
    log_event "Starting mainstream kernel update"
    
    if command -v pacman &> /dev/null; then
        # Arch Linux
        pacman -Syu --noconfirm
    elif command -v apt &> /dev/null; then
        # Debian/Ubuntu
        apt update && apt upgrade -y
    elif command -v dnf &> /dev/null; then
        # Fedora/RHEL
        dnf upgrade -y
    fi
    
    log_event "Mainstream kernel update complete"
}

# Function to update multikernel kernel
update_multikernel() {
    if [ "${AUTO_UPDATE_MULTIKERNEL:-false}" != "true" ]; then
        log_event "Multikernel update skipped - disabled by config" "INFO"
        return 0
    fi
    log_event "Starting multikernel kernel update"
    
    # Check for multikernel updates
    if [ -d "/opt/multikernel/linux" ]; then
        cd /opt/multikernel/linux
        
        # Pull latest changes
        git pull origin main
        
        # Rebuild kernel
        make -j$(nproc)
        make modules_install install
        
        # Update initramfs
        mkinitcpio -P
        
        log_event "Multikernel kernel update complete"
    else
        log_event "Multikernel source not found, skipping" "WARN"
    fi
}

# Function to sync to child kernel
sync_to_child() {
    if [ "${AUTO_SYNC_CHILD:-false}" != "true" ]; then
        log_event "Child sync skipped - disabled by config" "INFO"
        return 0
    fi
    log_event "Syncing updates to child kernel"
    
    local child_root="${CHILD_ROOT_DEVICE:-/dev/sdb2}"
    
    if [ -b "${child_root}" ]; then
        mkdir -p "${CHILD_ROOT}"
        local root_fs
        root_fs=$(blkid -s TYPE -o value "${child_root}" 2>/dev/null || echo "ext4")
        mount -t "${root_fs}" "${child_root}" "${CHILD_ROOT}"
        
        # Sync kernel files
        rsync -av --delete /boot/ "${CHILD_ROOT}/boot/"
        
        # Sync modules
        rsync -av --delete /lib/modules/ "${CHILD_ROOT}/lib/modules/"
        
        # Unmount
        umount "${CHILD_ROOT}"
        
        log_event "Updates synced to child kernel"
    else
        log_event "Child disk not found, skipping sync" "WARN"
    fi
}

# Function to create backup
create_backup() {
    log_event "Creating backup"
    
    local backup_dir="${UPDATE_DIR}/backup"
    mkdir -p "${backup_dir}"
    
    local backup_name="backup-$(date +%Y%m%d-%H%M%S)"
    
    # Backup current kernel
    tar -czf "${backup_dir}/${backup_name}-kernel.tar.gz" /boot/
    
    log_event "Backup created: ${backup_name}"
}

# Main function
main() {
    log_event "Starting update process"
    
    # Create backup
    create_backup
    
    # Update mainstream kernel
    update_mainstream
    
    # Update multikernel kernel
    update_multikernel
    
    # Sync to child kernel
    sync_to_child
    
    log_event "Update process complete"
}

# Run main function
main "$@"
EOF
sed -i "s|REPO_CONFIG_PLACEHOLDER|${SCRIPT_DIR}/../etc/proj-mk-ultra.conf|" "${UPDATE_DIR}/update.sh"
    
    chmod +x "${UPDATE_DIR}/update.sh"
    
    show_status "OK" "Update script created"
}

# Function to create systemd service
create_systemd_service() {
    show_step "Creating Systemd Service" 4
    
    cat > /etc/systemd/system/suspicious-updates.service << EOF
[Unit]
Description=SUSPICIOUS Framework Update Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${UPDATE_DIR}/update.sh
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
    
    cat > /etc/systemd/system/suspicious-updates.timer << 'EOF'
[Unit]
Description=SUSPICIOUS Framework Update Timer
Requires=suspicious-updates.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    show_status "OK" "Systemd service created"
}

# Function to enable update service
enable_update_service() {
    show_step "Enabling Update Service" 5
    
    # Reload systemd
    systemctl daemon-reload
    
    # Arm the daily timer only when at least one auto-update stage is on -
    # the wrapper no-ops disabled stages, but an idle daily timer is noise
    if [ "${AUTO_UPDATE_MAINSTREAM:-false}" = "true" ] || \
       [ "${AUTO_UPDATE_MULTIKERNEL:-false}" = "true" ] || \
       [ "${AUTO_SYNC_CHILD:-false}" = "true" ]; then
        systemctl enable suspicious-updates.timer
        systemctl start suspicious-updates.timer
        show_status "OK" "Update service enabled (stages gated per config)"
    else
        show_status "INFO" "All auto-updates disabled by config - timer not armed"
    fi
}

# Install the repo config to the system path so the installed wrapper
# resolves one source of truth for the auto-update flags
install_system_config() {
    mkdir -p /etc/proj-mk-ultra
    cp "${SCRIPT_DIR}/../etc/proj-mk-ultra.conf" /etc/proj-mk-ultra/proj-mk-ultra.conf
    show_status "OK" "System config installed: /etc/proj-mk-ultra/proj-mk-ultra.conf"
}

# Function to create manual update script
create_manual_update_script() {
    show_step "Creating Manual Update Script" 6
    
    cat > /usr/local/bin/suspicious-update << 'EOF'
#!/usr/bin/env bash
# suspicious-update - Manual update for SUSPICIOUS Framework

set -euo pipefail

echo "SUSPICIOUS Framework Update"
echo "=========================="
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Run update
echo "Running update..."
/opt/suspicious/updates/update.sh

echo
echo "Update complete!"
EOF
    
    chmod +x /usr/local/bin/suspicious-update
    
    show_status "OK" "Manual update script created"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  UPDATE SYSTEM SETUP COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Update directory: ${UPDATE_DIR}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Update Schedule:${NC}"
    echo -e "  Automatic: Daily at midnight"
    echo -e "  Manual: sudo suspicious-update"
    echo
    
    echo -e "${BOLD}What Gets Updated:${NC}"
    echo -e "  1. Mainstream kernel (via package manager)"
    echo -e "  2. Multikernel kernel (from source)"
    echo -e "  3. Child kernel (synced from host)"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Continue: sudo ./2_setup.sh (prevention/detection phases)"
    echo "  2. Reboot and select child kernel from boot menu"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    install_system_config
    create_update_directories
    create_update_script
    create_systemd_service
    enable_update_service
    create_manual_update_script
    
    show_summary
}

# Run main function
main "$@"
