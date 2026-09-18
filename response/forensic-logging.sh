#!/usr/bin/env bash
# forensic-logging.sh - Log forensic information
# SUSPICIOUS Framework: Response Layer
#
# Actions:
# - Collect system state
# - Log security events
# - Create audit trail
# - Preserve evidence
#
# Usage: sudo ./forensic-logging.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

FORENSIC_DIR="/opt/suspicious/forensic"
LOG_FILE="/var/log/suspicious-forensic.log"
AUDIT_LOG="/var/log/suspicious-audit.log"

cleanup_on_error() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo -e "\n${RED}${BOLD}[ERROR] Forensic logging failed with exit code ${exit_code}${NC}"
    fi
    exit ${exit_code}
}

trap cleanup_on_error EXIT

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         FORENSIC LOGGING SYSTEM                                    ║
║         SUSPICIOUS Framework Response Layer                         ║
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

# Function to log event
log_event() {
    local event="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $event" >> "${LOG_FILE}"
    logger -t suspicious-forensic "$level: $event"
}

# Function to create forensic directory
create_forensic_directory() {
    show_step "Creating Forensic Directory" 1
    
    mkdir -p "${FORENSIC_DIR}"
    
    show_status "OK" "Forensic directory created: ${FORENSIC_DIR}"
}

# Function to collect system information
collect_system_information() {
    show_step "Collecting System Information" 2
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local evidence_dir="${FORENSIC_DIR}/system-${timestamp}"
    
    mkdir -p "${evidence_dir}"
    
    # Collect kernel information
    echo -e "\n${BOLD}  Collecting kernel information...${NC}"
    uname -a > "${evidence_dir}/uname.txt"
    cat /proc/version > "${evidence_dir}/version.txt"
    cat /proc/cmdline > "${evidence_dir}/cmdline.txt"
    cat /proc/sys/kernel/tainted > "${evidence_dir}/tainted.txt"
    
    # Collect loaded modules
    echo -e "${BOLD}  Collecting loaded modules...${NC}"
    lsmod > "${evidence_dir}/lsmod.txt"
    
    # Collect process information
    echo -e "${BOLD}  Collecting process information...${NC}"
    ps aux > "${evidence_dir}/ps_aux.txt"
    ps -ef > "${evidence_dir}/ps_ef.txt"
    ps -eo pid,ppid,cmd --forest > "${evidence_dir}/ps_forest.txt"
    
    # Collect network information
    echo -e "${BOLD}  Collecting network information...${NC}"
    ss -tuln > "${evidence_dir}/ss_tuln.txt"
    ss -tnp > "${evidence_dir}/ss_tnp.txt"
    ip addr > "${evidence_dir}/ip_addr.txt"
    ip route > "${evidence_dir}/ip_route.txt"
    iptables -L -n > "${evidence_dir}/iptables.txt"
    
    # Collect filesystem information
    echo -e "${BOLD}  Collecting filesystem information...${NC}"
    df -h > "${evidence_dir}/df_h.txt"
    mount > "${evidence_dir}/mount.txt"
    lsblk > "${evidence_dir}/lsblk.txt"
    fdisk -l > "${evidence_dir}/fdisk.txt"
    
    # Collect multikernel information
    echo -e "${BOLD}  Collecting multikernel information...${NC}"
    if [ -d "/sys/fs/multikernel" ]; then
        find /sys/fs/multikernel -type f > "${evidence_dir}/multikernel_files.txt"
        for file in /sys/fs/multikernel/*/status; do
            if [ -f "${file}" ]; then
                echo "=== ${file} ===" >> "${evidence_dir}/multikernel_status.txt"
                cat "${file}" >> "${evidence_dir}/multikernel_status.txt"
                echo "" >> "${evidence_dir}/multikernel_status.txt"
            fi
        done
    fi
    
    # Collect IOMMU information
    echo -e "${BOLD}  Collecting IOMMU information...${NC}"
    if [ -d "/sys/kernel/iommu_groups" ]; then
        ls -la /sys/kernel/iommu_groups/ > "${evidence_dir}/iommu_groups.txt"
        for group in /sys/kernel/iommu_groups/*/devices/*; do
            if [ -e "${group}" ]; then
                echo "$(basename "${group}")" >> "${evidence_dir}/iommu_devices.txt"
            fi
        done
    fi
    
    # Create tarball
    echo -e "${BOLD}  Creating evidence tarball...${NC}"
    tar -czf "${evidence_dir}.tar.gz" -C "${FORENSIC_DIR}" "$(basename "${evidence_dir}")"
    rm -rf "${evidence_dir}"
    
    show_status "OK" "System information collected: ${evidence_dir}.tar.gz"
    log_event "System information collected: ${evidence_dir}.tar.gz"
}

# Function to log security events
log_security_events() {
    show_step "Logging Security Events" 3
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local events_file="${FORENSIC_DIR}/security-events-${timestamp}.txt"
    
    # Collect security-related logs
    echo -e "\n${BOLD}  Collecting security logs...${NC}"
    
    # Authentication logs
    if [ -f /var/log/auth.log ]; then
        echo "=== Authentication Logs ===" > "${events_file}"
        tail -100 /var/log/auth.log >> "${events_file}"
        echo "" >> "${events_file}"
    fi
    
    # System logs
    if [ -f /var/log/syslog ]; then
        echo "=== System Logs ===" >> "${events_file}"
        tail -100 /var/log/syslog >> "${events_file}"
        echo "" >> "${events_file}"
    fi
    
    # Kernel logs
    echo "=== Kernel Logs ===" >> "${events_file}"
    dmesg | tail -100 >> "${events_file}"
    echo "" >> "${events_file}"
    
    # Audit logs
    if [ -f /var/log/audit/audit.log ]; then
        echo "=== Audit Logs ===" >> "${events_file}"
        tail -100 /var/log/audit/audit.log >> "${events_file}"
        echo "" >> "${events_file}"
    fi
    
    show_status "OK" "Security events logged: ${events_file}"
    log_event "Security events logged: ${events_file}"
}

# Function to create audit trail
create_audit_trail() {
    show_step "Creating Audit Trail" 4
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local audit_file="${FORENSIC_DIR}/audit-trail-${timestamp}.txt"
    
    # Create audit trail
    echo "=== SUSPICIOUS Framework Audit Trail ===" > "${audit_file}"
    echo "Timestamp: $(date -Iseconds)" >> "${audit_file}"
    echo "Host: $(hostname)" >> "${audit_file}"
    echo "User: $(whoami)" >> "${audit_file}"
    echo "" >> "${audit_file}"
    
    # System state
    echo "=== System State ===" >> "${audit_file}"
    echo "Kernel: $(uname -r)" >> "${audit_file}"
    echo "Tainted: $(cat /proc/sys/kernel/tainted)" >> "${audit_file}"
    echo "Uptime: $(uptime)" >> "${audit_file}"
    echo "" >> "${audit_file}"
    
    # Security configuration
    echo "=== Security Configuration ===" >> "${audit_file}"
    echo "SELinux: $(getenforce 2>/dev/null || echo "N/A")" >> "${audit_file}"
    echo "AppArmor: $(aa-status 2>/dev/null || echo "N/A")" >> "${audit_file}"
    echo "Firewall: $(iptables -L -n 2>/dev/null | head -5)" >> "${audit_file}"
    echo "" >> "${audit_file}"
    
    show_status "OK" "Audit trail created: ${audit_file}"
    log_event "Audit trail created: ${audit_file}"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  FORENSIC LOGGING COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Forensic directory: ${FORENSIC_DIR}"
    echo -e "  Log file: ${LOG_FILE}"
    echo -e "  Audit log: ${AUDIT_LOG}"
    echo
    
    echo -e "${BOLD}Evidence Collected:${NC}"
    echo -e "  ${GREEN}→ System information${NC}"
    echo -e "  ${GREEN}→ Security events${NC}"
    echo -e "  ${GREEN}→ Audit trail${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Review evidence in ${FORENSIC_DIR}"
    echo "  2. Analyze security events"
    echo "  3. Investigate root cause"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    # Install mode: prepare forensic directories only - evidence collection
    # runs at trigger time, not setup time
    if [ "${1:-}" = "--install" ]; then
        create_forensic_directory
        show_status "OK" "Forensic directories ready"
        show_status "OK" "Audit trail armed: system info + security events on trigger"
        log_event "Forensic logging installed (configure-only)"
        show_summary
        exit 0
    fi
    
    log_event "Forensic logging started"
    
    create_forensic_directory
    collect_system_information
    log_security_events
    create_audit_trail
    
    log_event "Forensic logging completed"
    
    show_summary
}

# Run main function
main "$@"
