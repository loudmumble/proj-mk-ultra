#!/usr/bin/env bash
# monitor-sysfs-access.sh - Monitor /sys/fs/multikernel access
# SUSPICIOUS Framework: Detection Layer
#
# Monitors:
# - Multikernel sysfs modifications
# - Instance configuration changes
# - Control interface access
# - Status changes
#
# Usage: sudo ./monitor-sysfs-access.sh

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
MULTIKERNEL_SYSFS="/sys/fs/multikernel"
MONITOR_DIR="/opt/suspicious/monitoring"
LOG_FILE="/var/log/suspicious-sysfs-monitor.log"
STATE_FILE="${MONITOR_DIR}/sysfs-state.json"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         SYSFS ACCESS MONITOR                                       ║
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

# Function to check multikernel sysfs
check_multikernel_sysfs() {
    show_step "Checking Multikernel Sysfs" 2
    
    if [ -d "${MULTIKERNEL_SYSFS}" ]; then
        show_status "OK" "Multikernel sysfs mounted"
        
        # Check instances directory
        if [ -d "${MULTIKERNEL_SYSFS}/instances" ]; then
            show_status "OK" "Instances directory exists"
            
            # List instances
            local instances
            instances=$(ls -1 "${MULTIKERNEL_SYSFS}/instances" 2>/dev/null)
            
            if [ -n "${instances}" ]; then
                echo -e "\n${BOLD}  Instances:${NC}"
                echo "${instances}" | while read instance; do
                    echo -e "    - ${instance}"
                done
            else
                show_status "INFO" "No instances configured"
            fi
        else
            show_status "WARN" "Instances directory not found"
        fi
    else
        show_status "ERROR" "Multikernel sysfs not mounted"
        echo -e "    Mount with: mount -t multikernel none /sys/fs/multikernel"
    fi
}

# Function to check instance configuration
check_instance_configuration() {
    show_step "Checking Instance Configuration" 3
    
    if [ ! -d "${MULTIKERNEL_SYSFS}/instances" ]; then
        show_status "WARN" "No instances directory"
        return
    fi
    
    for instance in "${MULTIKERNEL_SYSFS}/instances"/*/; do
        if [ -d "${instance}" ]; then
            local instance_name
            instance_name=$(basename "${instance}")
            
            echo -e "\n${BOLD}  Instance: ${instance_name}${NC}"
            
            # Check status
            if [ -f "${instance}/status" ]; then
                local status
                status=$(cat "${instance}/status")
                echo -e "    Status: ${status}"
            fi
            
            # Check device tree (exported by the core for every instance)
            if [ -f "${instance}/device_tree" ]; then
                show_status "OK" "Instance device tree present"
            else
                show_status "WARN" "No instance device tree"
            fi
            
            # Check control
            if [ -f "${instance}/control" ]; then
                show_status "OK" "Control interface available"
            else
                show_status "WARN" "No control interface"
            fi
        fi
    done
}

# Function to save sysfs state
save_sysfs_state() {
    show_step "Saving Sysfs State" 4
    
    # Save current sysfs state
    cat > "${STATE_FILE}" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "sysfs_mounted": $([ -d "${MULTIKERNEL_SYSFS}" ] && echo "true" || echo "false"),
    "instances_count": $(ls -1 "${MULTIKERNEL_SYSFS}/instances" 2>/dev/null | wc -l),
    "instances": [$(ls -1 "${MULTIKERNEL_SYSFS}/instances" 2>/dev/null | sed 's/^/"/;s/$/"/' | tr '\n' ',')]
}
EOF
    
    show_status "OK" "Sysfs state saved"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  SYSFS ACCESS MONITORING COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Monitoring directory: ${MONITOR_DIR}"
    echo -e "  State file: ${STATE_FILE}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Sysfs Features Monitored:${NC}"
    echo -e "  ${GREEN}→ Multikernel sysfs mount status${NC}"
    echo -e "  ${GREEN}→ Instance configuration${NC}"
    echo -e "  ${GREEN}→ Control interface access${NC}"
    echo -e "  ${GREEN}→ Status changes${NC}"
    echo
    
    echo -e "${BOLD}Security Features:${NC}"
    echo -e "  ${GREEN}→ Tamper detection${NC}"
    echo -e "  ${GREEN}→ Configuration tracking${NC}"
    echo -e "  ${GREEN}→ Audit logging${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./monitor-module-loading.sh"
    echo "  2. Run: sudo ./monitor-behavioral-anomalies.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    create_monitoring_directory
    check_multikernel_sysfs
    check_instance_configuration
    save_sysfs_state
    
    show_summary
}

# Run main function
main "$@"
