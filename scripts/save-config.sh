#!/usr/bin/env bash
# save-config.sh - Save PROJ-MK-ULTRA configuration
# SUSPICIOUS Framework: Configuration Infrastructure
#
# CLI for reading/writing config keys. Supports set/get/list/reset.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${PROJ_MK_ULTRA_CONFIG:-${SCRIPT_DIR}/../etc/proj-mk-ultra.conf}"

# Update existing key or append new one
save_config() {
    local key="$1"
    local value="$2"
    
    mkdir -p "$(dirname "${CONFIG_FILE}")"
    
    if [ -f "${CONFIG_FILE}" ] && grep -q "^${key}=" "${CONFIG_FILE}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${CONFIG_FILE}"
    else
        echo "${key}=\"${value}\"" >> "${CONFIG_FILE}"
    fi
}

# Read a config value directly from file (no env needed)
get_config() {
    local key="$1"
    local default="${2:-}"
    
    if [ -f "${CONFIG_FILE}" ] && grep -q "^${key}=" "${CONFIG_FILE}" 2>/dev/null; then
        grep "^${key}=" "${CONFIG_FILE}" | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d ' '
    else
        echo "${default}"
    fi
}

# Display all non-comment, non-blank config lines
list_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "No configuration file found."
        return 1
    fi
    
    echo "Current configuration:"
    while IFS='=' read -r key value; do
        key=$(echo "${key}" | tr -d ' ')
        value=$(echo "${value}" | tr -d '"' | tr -d ' ')
        
        case "${key}" in
            \#*|"") continue ;;
            *) echo "  ${key}=${value}" ;;
        esac
    done < "${CONFIG_FILE}"
}

# Overwrite config with hardcoded defaults
reset_config() {
    cat > "${CONFIG_FILE}" << 'EOF'
# PROJ-MK-ULTRA Configuration
# SUSPICIOUS Framework - User Configuration
# Keys MUST be valid bash variable names (UPPERCASE_UNDERSCORE).

# Host Configuration
CORE_HOST_FILESYSTEM="ext4"
SECURITY_LEVEL="basic"

# Leapfrog Filesystem Diversity
CHILD_LEAPFROG_FS_ENABLE="false"
CHILD_LEAPFROG_FS="btrfs"
CHILD_LEAPFROG_ALT="xfs"

# Cross-Distro Support
CROSS_DISTRO_ENABLE="false"
CHILD_DISTRO="arch"

# Installation Target
INSTALL_TARGET="secondary-disk"

# Child Kernel Configuration
CHILD_ROOT_SIZE="20G"
CHILD_BOOT_SIZE="512M"
CHILD_DATA_SIZE="100%"

# Child Instance Hardware Assignment
CHILD_CPU_MASK="0xFFFFFFF0"
CHILD_MEMORY_SIZE="112G"
MOVABLECORE="116G"
PASSTHROUGH_PCI_DEVICES="01:00.0"
MEMORY_RESERVATION_ACKNOWLEDGED="false"
CHILD_KERNEL_PATH=""
CHILD_INITRD_PATH=""
SPAWN_KEEP_BOUND="true"

# Security Settings
MODULE_SIGNING_ENFORCE="true"
IOMMU_VERIFY="true"
CAPABILITY_DROPPING="true"
FILESYSTEM_ISOLATION="true"
NETWORK_ISOLATION="true"

# Detection Settings
BOOT_INTEGRITY_MONITOR="true"
HARDWARE_ISOLATION_MONITOR="true"
SYSFS_ACCESS_MONITOR="true"
MODULE_LOADING_MONITOR="true"
BEHAVIORAL_ANOMALY_DETECTION="true"

# Response Settings
AUTO_DESTROY_ON_DETECTION="true"
PRESERVE_USER_DATA="true"
FORENSIC_LOGGING="true"
RECOVERY_PROCEDURES="true"

# Update Settings
AUTO_UPDATE_MAINSTREAM="false"
AUTO_UPDATE_MULTIKERNEL="false"
AUTO_SYNC_CHILD="false"

# Btrfs Snapshot Settings (Advanced)
BTRFS_SNAPSHOT_ENABLE="false"
BTRFS_SNAPSHOT_KEEP="5"

# Disk Configuration
TARGET_DISK=""
CHILD_BOOT_DEVICE=""
CHILD_ROOT_DEVICE=""
CHILD_DATA_DEVICE=""
EOF
    
    echo "Configuration reset to defaults."
}

# CLI dispatch when run directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        set)
            save_config "${2}" "${3}"
            echo "Set ${2}=${3}"
            ;;
        get)
            get_config "${2}" "${3:-}"
            ;;
        list)
            list_config
            ;;
        reset)
            reset_config
            ;;
        *)
            echo "Usage: $0 {set|get|list|reset} [key] [value]"
            exit 1
            ;;
    esac
fi
