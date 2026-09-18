#!/usr/bin/env bash
# load-config.sh - Load PROJ-MK-ULTRA configuration
# SUSPICIOUS Framework: Configuration Infrastructure
#
# Sourced by other scripts to load config keys into environment.
# Can also be run directly to display current settings.

set -euo pipefail

# Uses config: all keys from proj-mk-ultra.conf
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${PROJ_MK_ULTRA_CONFIG:-${SCRIPT_DIR}/../etc/proj-mk-ultra.conf}"

load_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "ERROR: Configuration file not found: ${CONFIG_FILE}" >&2
        return 1
    fi
    
    # Parse key=value pairs, skip comments and blank lines
    while IFS='=' read -r key value; do
        key=$(echo "${key}" | tr -d ' ')
        value=$(echo "${value}" | tr -d '"' | tr -d ' ')
        
        case "${key}" in
            \#*|"") continue ;;
            # Export as PROJ_MK_<key> for environment access
            *) export "PROJ_MK_${key}"="${value}" ;;
        esac
    done < "${CONFIG_FILE}"
    
    return 0
}

# Retrieve a config value by key with optional default
get_config() {
    local key="$1"
    local default="${2:-}"
    
    local env_key="PROJ_MK_${key}"
    echo "${!env_key:-${default}}"
}

# Run directly to display loaded config
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    load_config
    
    echo "Configuration loaded from: ${CONFIG_FILE}"
    echo
    echo "Current settings:"
    while IFS='=' read -r key value; do
        key=$(echo "${key}" | tr -d ' ')
        value=$(echo "${value}" | tr -d '"' | tr -d ' ')
        
        case "${key}" in
            \#*|"") continue ;;
            *) echo "  ${key}=${value}" ;;
        esac
    done < "${CONFIG_FILE}"
fi
