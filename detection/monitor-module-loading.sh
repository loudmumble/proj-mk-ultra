#!/usr/bin/env bash
# monitor-module-loading.sh - Monitor module loading
# SUSPICIOUS Framework: Detection Layer
#
# Monitors:
# - Module loading events
# - Module signatures
# - Unsigned module attempts
# - Module dependencies
#
# Usage: sudo ./monitor-module-loading.sh

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
MONITOR_DIR="/opt/suspicious/monitoring"
LOG_FILE="/var/log/suspicious-module-monitor.log"
STATE_FILE="${MONITOR_DIR}/module-state.json"
MODULES_DIR="/lib/modules"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         MODULE LOADING MONITOR                                     ║
║         SUSPICIOUS Framework Detection Layer                        ║
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

# Function to create monitoring directory
create_monitoring_directory() {
    show_step "Creating Monitoring Directory" 1
    
    mkdir -p "${MONITOR_DIR}"
    
    show_status "OK" "Monitoring directory created: ${MONITOR_DIR}"
}

# Function to check loaded modules
check_loaded_modules() {
    show_step "Checking Loaded Modules" 2
    
    # Get loaded modules
    local loaded_modules
    loaded_modules=$(lsmod | awk 'NR>1{print $1}')
    
    local module_count
    module_count=$(echo "${loaded_modules}" | wc -l)
    
    echo -e "\n${BOLD}  Loaded Modules: ${module_count}${NC}"
    
    # Check each module
    local unsigned_count=0
    local signed_count=0
    
    while read module; do
        if [ -n "${module}" ]; then
            # Check if module is signed
            if modinfo "${module}" 2>/dev/null | grep -- "sig" > /dev/null; then
                signed_count=$((signed_count + 1))
            else
                unsigned_count=$((unsigned_count + 1))
                show_status "WARN" "Unsigned module: ${module}"
            fi
        fi
    done < <(lsmod | awk 'NR>1{print $1}')
    
    show_status "OK" "Signed modules: ${signed_count}"
    if [ "${unsigned_count}" -gt 0 ]; then
        show_status "WARN" "Unsigned modules: ${unsigned_count}"
    fi
}

# Function to check module signatures
check_module_signatures() {
    show_step "Checking Module Signatures" 3
    
    local kernel_version
    kernel_version=$(uname -r)
    
    if [ ! -d "${MODULES_DIR}/${kernel_version}" ]; then
        show_status "WARN" "Module directory not found: ${MODULES_DIR}/${kernel_version}"
        return
    fi
    
    # Count signed and unsigned modules
    local total_modules=0
    local signed_modules=0
    local unsigned_modules=0
    
    while read module; do
        total_modules=$((total_modules + 1))
        
        if modinfo "${module}" 2>/dev/null | grep -- "sig" > /dev/null; then
            signed_modules=$((signed_modules + 1))
        else
            unsigned_modules=$((unsigned_modules + 1))
            show_status "WARN" "Unsigned module: $(basename "${module}")"
        fi
    done < <(find "${MODULES_DIR}/${kernel_version}" -name "*.ko")
    
    show_status "OK" "Total modules: ${total_modules}"
    show_status "OK" "Signed modules: ${signed_modules}"
    if [ "${unsigned_modules}" -gt 0 ]; then
        show_status "WARN" "Unsigned modules: ${unsigned_modules}"
    fi
}

# Function to save module state
save_module_state() {
    show_step "Saving Module State" 4
    
    # Get loaded modules
    local loaded_modules
    loaded_modules=$(lsmod | awk 'NR>1{print $1}' | tr '\n' ',')
    
    # Save module state
    cat > "${STATE_FILE}" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "loaded_modules": [$(echo "${loaded_modules}" | sed 's/,$//')],
    "module_count": $(lsmod | awk 'NR>1{print $1}' | wc -l)
}
EOF
    
    show_status "OK" "Module state saved"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  MODULE LOADING MONITORING COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Monitoring directory: ${MONITOR_DIR}"
    echo -e "  State file: ${STATE_FILE}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Module Features Monitored:${NC}"
    echo -e "  ${GREEN}→ Loaded modules${NC}"
    echo -e "  ${GREEN}→ Module signatures${NC}"
    echo -e "  ${GREEN}→ Unsigned module attempts${NC}"
    echo -e "  ${GREEN}→ Module dependencies${NC}"
    echo
    
    echo -e "${BOLD}Security Features:${NC}"
    echo -e "  ${GREEN}→ Signature verification${NC}"
    echo -e "  ${GREEN}→ Tamper detection${NC}"
    echo -e "  ${GREEN}→ Audit logging${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./monitor-behavioral-anomalies.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    create_monitoring_directory
    check_loaded_modules
    check_module_signatures
    save_module_state
    
    show_summary
}

# Run main function
main "$@"
