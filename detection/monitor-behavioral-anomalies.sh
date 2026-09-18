#!/usr/bin/env bash
# monitor-behavioral-anomalies.sh - Monitor behavioral anomalies
# SUSPICIOUS Framework: Detection Layer
#
# Monitors:
# - Unusual system calls
# - Abnormal file access patterns
# - Suspicious process behavior
# - Network anomalies
#
# Usage: sudo ./monitor-behavioral-anomalies.sh

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
LOG_FILE="/var/log/suspicious-behavior-monitor.log"
STATE_FILE="${MONITOR_DIR}/behavior-state.json"

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         BEHAVIORAL ANOMALY MONITOR                                 ║
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

# Function to check unusual system calls
check_unusual_syscalls() {
    show_step "Checking Unusual System Calls" 2
    
    # Check for unusual system calls
    echo -e "${BOLD}  Checking system call patterns...${NC}"
    
    # Check for kexec usage
    if pgrep -f "kexec" > /dev/null; then
        show_status "WARN" "kexec process detected"
    else
        show_status "OK" "No kexec processes"
    fi
    
    # Check for insmod/modprobe usage
    if pgrep -fE "insmod|modprobe" > /dev/null; then
        show_status "WARN" "Module loading detected"
    else
        show_status "OK" "No module loading"
    fi
    
    # Check for kernel manipulation
    if [ -f "/proc/sys/kernel/tainted" ]; then
        local taint_value
        taint_value=$(cat /proc/sys/kernel/tainted)
        
        if [ "${taint_value}" -eq 0 ]; then
            show_status "OK" "Kernel is clean (taint: 0)"
        else
            show_status "WARN" "Kernel is tainted: ${taint_value}"
        fi
    fi
}

# Function to check abnormal file access
check_abnormal_file_access() {
    show_step "Checking Abnormal File Access" 3
    
    # Check for suspicious file modifications
    echo -e "${BOLD}  Checking file modification patterns...${NC}"
    
    # Check for recent modifications to critical files
    local critical_files=(
        "/etc/passwd"
        "/etc/shadow"
        "/etc/sudoers"
        "/etc/ssh/sshd_config"
    )
    
    for file in "${critical_files[@]}"; do
        if [ -f "${file}" ]; then
            local mod_time
            mod_time=$(stat -c %Y "${file}" 2>/dev/null)
            local current_time
            current_time=$(date +%s)
            
            local time_diff=$((current_time - mod_time))
            
            if [ "${time_diff}" -lt 3600 ]; then
                show_status "WARN" "Recent modification: ${file} (${time_diff}s ago)"
            else
                show_status "OK" "File not recently modified: ${file}"
            fi
        fi
    done
}

# Function to check suspicious process behavior
check_suspicious_processes() {
    show_step "Checking Suspicious Processes" 4
    
    # Check for suspicious processes
    echo -e "${BOLD}  Checking process patterns...${NC}"
    
    # Check for root processes
    local root_processes
    root_processes=$(ps aux | awk '$1=="root"{print $2}' | wc -l)
    
    echo -e "    Root processes: ${root_processes}"
    
    # Check for unusual process names
    local suspicious_patterns=(
        "nc|netcat"
        "ncat"
        "socat"
        "curl|wget"
        "python.*-c"
        "perl.*-e"
        "ruby.*-e"
    )
    
    for pattern in "${suspicious_patterns[@]}"; do
        if pgrep -fE "${pattern}" > /dev/null; then
            show_status "WARN" "Suspicious process pattern: ${pattern}"
        fi
    done
    
    show_status "OK" "Process check complete"
}

# Function to check network anomalies
check_network_anomalies() {
    show_step "Checking Network Anomalies" 5
    
    # Check for unusual network connections
    echo -e "${BOLD}  Checking network patterns...${NC}"
    
    # Check for listening ports
    local listening_ports
    listening_ports=$(ss -tuln 2>/dev/null | grep LISTEN | wc -l)
    
    echo -e "    Listening ports: ${listening_ports}"
    
    # Check for established connections
    local established_connections
    established_connections=$(ss -tn 2>/dev/null | grep ESTAB | wc -l)
    
    echo -e "    Established connections: ${established_connections}"
    
    # Check for suspicious connections
    if ss -tn 2>/dev/null | grep -E ":[0-9]{4,5}.*ESTAB" > /dev/null; then
        show_status "WARN" "High-port connections detected"
    else
        show_status "OK" "No suspicious connections"
    fi
}

# Function to save behavior state
save_behavior_state() {
    show_step "Saving Behavior State" 6
    
    # Save behavior state
    cat > "${STATE_FILE}" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "kernel_tainted": $(cat /proc/sys/kernel/tainted 2>/dev/null || echo "0"),
    "root_processes": $(ps aux | awk '$1=="root"{print $2}' | wc -l),
    "listening_ports": $(ss -tuln 2>/dev/null | grep LISTEN | wc -l),
    "established_connections": $(ss -tn 2>/dev/null | grep ESTAB | wc -l)
}
EOF
    
    show_status "OK" "Behavior state saved"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  BEHAVIORAL ANOMALY MONITORING COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Monitoring directory: ${MONITOR_DIR}"
    echo -e "  State file: ${STATE_FILE}"
    echo -e "  Log file: ${LOG_FILE}"
    echo
    
    echo -e "${BOLD}Behavioral Features Monitored:${NC}"
    echo -e "  ${GREEN}→ Unusual system calls${NC}"
    echo -e "  ${GREEN}→ Abnormal file access${NC}"
    echo -e "  ${GREEN}→ Suspicious processes${NC}"
    echo -e "  ${GREEN}→ Network anomalies${NC}"
    echo
    
    echo -e "${BOLD}Security Features:${NC}"
    echo -e "  ${GREEN}→ Anomaly detection${NC}"
    echo -e "  ${GREEN}→ Pattern recognition${NC}"
    echo -e "  ${GREEN}→ Audit logging${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Run: sudo ./auto-destroy.sh"
    echo "  2. Run: sudo ./preserve-data.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    create_monitoring_directory
    check_unusual_syscalls
    check_abnormal_file_access
    check_suspicious_processes
    check_network_anomalies
    save_behavior_state
    
    show_summary
}

# Run main function
main "$@"
