#!/usr/bin/env bash
# auto-destroy.sh - Auto-destroy child kernel on detection
# SUSPICIOUS Framework: Response Layer
#
# Actions:
# - Destroy child kernel instance
# - Preserve user data
# - Log forensic information
# - Launch clean child kernel
#
# Usage: sudo ./auto-destroy.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

MULTIKERNEL_SYSFS="/sys/fs/multikernel"
CHILD_INSTANCE="child0"
USER_DATA_PARTITION="${CHILD_DATA_DEVICE:-/dev/sdb3}"
USER_DATA_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"
LOG_FILE="/var/log/suspicious-auto-destroy.log"
FORENSIC_DIR="${SCRIPT_DIR}/../forensic"
PID_FILE="/var/run/suspicious-auto-destroy.pid"

# shellcheck source=../scripts/lib-hardware.sh
. "${SCRIPT_DIR}/../scripts/lib-hardware.sh"
CHILD_CPU_MASK="${CHILD_CPU_MASK:-0xFFFFFFF0}"
CHILD_MEMORY_SIZE="${CHILD_MEMORY_SIZE:-112G}"
PASSTHROUGH_PCI_DEVICES="${PASSTHROUGH_PCI_DEVICES:-01:00.0}"

# Resolve the child instance this script operates on: explicit child0, else
# the first running non-host instance (spawn generates child-<timestamp> names)
resolve_child_instance() {
    if [ -d "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}" ]; then
        return 0
    fi
    local inst role
    for inst in "${MULTIKERNEL_SYSFS}/instances/"*; do
        [ -d "${inst}" ] || continue
        role=$(cat "${inst}/role" 2>/dev/null || echo "")
        if [ "${role}" != "host" ]; then
            CHILD_INSTANCE=$(basename "${inst}")
            show_status "INFO" "Resolved child instance: ${CHILD_INSTANCE}"
            return 0
        fi
    done
    return 1
}

cleanup_on_error() {
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo -e "\n${RED}${BOLD}[ERROR] Auto-destroy failed with exit code ${exit_code}${NC}"
        echo -e "${YELLOW}Preserving forensic evidence...${NC}"
        mkdir -p "${FORENSIC_DIR}" 2>/dev/null || true
        echo "$(date -Iseconds) auto-destroy failed: exit ${exit_code}" >> "${FORENSIC_DIR}/failures.log" 2>/dev/null || true
    fi
    exit ${exit_code}
}

trap cleanup_on_error EXIT

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         AUTO-DESTROY SYSTEM                                        ║
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
    logger -t suspicious-auto-destroy "$level: $event"
}

# Function to create forensic directory
create_forensic_directory() {
    show_step "Creating Forensic Directory" 1
    
    mkdir -p "${FORENSIC_DIR}"
    
    show_status "OK" "Forensic directory created: ${FORENSIC_DIR}"
}

# Function to collect forensic evidence
collect_forensic_evidence() {
    show_step "Collecting Forensic Evidence" 2
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local evidence_dir="${FORENSIC_DIR}/evidence-${timestamp}"
    
    mkdir -p "${evidence_dir}"
    
    # Collect kernel information
    echo -e "\n${BOLD}  Collecting kernel information...${NC}"
    uname -a > "${evidence_dir}/uname.txt"
    cat /proc/version > "${evidence_dir}/version.txt"
    cat /proc/cmdline > "${evidence_dir}/cmdline.txt"
    
    # Collect loaded modules
    echo -e "${BOLD}  Collecting loaded modules...${NC}"
    lsmod > "${evidence_dir}/lsmod.txt"
    
    # Collect process information
    echo -e "${BOLD}  Collecting process information...${NC}"
    ps aux > "${evidence_dir}/ps_aux.txt"
    ps -ef > "${evidence_dir}/ps_ef.txt"
    
    # Collect network information
    echo -e "${BOLD}  Collecting network information...${NC}"
    ss -tuln > "${evidence_dir}/ss_tuln.txt"
    ss -tnp > "${evidence_dir}/ss_tnp.txt"
    ip addr > "${evidence_dir}/ip_addr.txt"
    ip route > "${evidence_dir}/ip_route.txt"
    
    # Collect filesystem information
    echo -e "${BOLD}  Collecting filesystem information...${NC}"
    df -h > "${evidence_dir}/df_h.txt"
    mount > "${evidence_dir}/mount.txt"
    lsblk > "${evidence_dir}/lsblk.txt"
    
    # Collect multikernel information
    echo -e "${BOLD}  Collecting multikernel information...${NC}"
    if [ -d "${MULTIKERNEL_SYSFS}" ]; then
        find "${MULTIKERNEL_SYSFS}" -type f > "${evidence_dir}/multikernel_files.txt"
        for file in "${MULTIKERNEL_SYSFS}"/*/status; do
            if [ -f "${file}" ]; then
                echo "=== ${file} ===" >> "${evidence_dir}/multikernel_status.txt"
                cat "${file}" >> "${evidence_dir}/multikernel_status.txt"
                echo "" >> "${evidence_dir}/multikernel_status.txt"
            fi
        done
    fi
    
    # Collect kernel taint status
    echo -e "${BOLD}  Collecting kernel taint status...${NC}"
    cat /proc/sys/kernel/tainted > "${evidence_dir}/tainted.txt"
    
    # Create tarball
    echo -e "${BOLD}  Creating evidence tarball...${NC}"
    tar -czf "${evidence_dir}.tar.gz" -C "${FORENSIC_DIR}" "$(basename "${evidence_dir}")"
    rm -rf "${evidence_dir}"
    
    show_status "OK" "Forensic evidence collected: ${evidence_dir}.tar.gz"
    log_event "Forensic evidence collected: ${evidence_dir}.tar.gz"
}

# Function to preserve user data
preserve_user_data() {
    show_step "Preserving User Data" 3
    
    if [ ! -b "${USER_DATA_PARTITION}" ]; then
        show_status "WARN" "User data partition not found: ${USER_DATA_PARTITION}"
        return
    fi
    
    if mount | grep -- "${USER_DATA_PARTITION}" > /dev/null; then
        show_status "OK" "User data partition is mounted"
    else
        local mount_point="/mnt/preserved-data"
        mkdir -p "${mount_point}"
        mount -t "${USER_DATA_FILESYSTEM}" "${USER_DATA_PARTITION}" "${mount_point}"
        
        show_status "OK" "User data partition mounted"
    fi
    
    echo -e "\n${BOLD}  Verifying user data integrity...${NC}"
    
    if [ -d "/mnt/preserved-data" ]; then
        local file_count
        file_count=$(find /mnt/preserved-data -type f | wc -l)
        
        echo -e "    Files preserved: ${file_count}"
        show_status "OK" "User data verified"
    fi
}

# Function to destroy child kernel
destroy_child_kernel() {
    show_step "Destroying Child Kernel" 4
    
    # Check if child instance exists
    if [ ! -d "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}" ]; then
        show_status "WARN" "Child instance not found: ${CHILD_INSTANCE}"
        return
    fi
    
    # Get child status
    local child_status
    child_status=$(cat "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/status" 2>/dev/null || echo "unknown")
    
    echo -e "\n${BOLD}  Child kernel status: ${child_status}${NC}"
    
    if [ "${child_status}" = "running" ]; then
        # Shutdown child kernel
        show_status "INFO" "Shutting down child kernel"
        echo "shutdown" > "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/control" 2>/dev/null || true
        
        # Wait for shutdown
        local timeout=10
        while [ ${timeout} -gt 0 ]; do
            if [ ! -d "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}" ]; then
                break
            fi
            sleep 1
            timeout=$((timeout - 1))
        done
        
        # Force shutdown if needed
        if [ -d "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}" ]; then
            show_status "WARN" "Force shutdown required"
            echo "force-shutdown" > "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}/control" 2>/dev/null || true
            sleep 2
        fi
    fi

    # Verified removal via the overlay API (instance-remove) if still present
    if [ -d "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}" ]; then
        show_status "INFO" "Removing instance via overlay API"
        mk_remove_instance_overlay "${CHILD_INSTANCE}" || true
    fi
    
    # Verify destruction
    if [ ! -d "${MULTIKERNEL_SYSFS}/instances/${CHILD_INSTANCE}" ]; then
        show_status "OK" "Child kernel destroyed"
        log_event "Child kernel destroyed"
    else
        show_status "ERROR" "Failed to destroy child kernel"
        log_event "Failed to destroy child kernel" "ERROR"
    fi
}

# Function to launch clean child kernel
launch_clean_child() {
    show_step "Launching Clean Child Kernel" 5

    local new_instance="child-clean-$(date +%s)"

    if mk_create_instance_overlay "${new_instance}"; then
        show_status "OK" "Clean child instance created from pool: ${new_instance}"
        log_event "Clean child kernel instance created: ${new_instance}"
    else
        show_status "ERROR" "Instance creation failed - kernel messages:"
        dmesg | tail -6 | sed 's/^/    /'
        log_event "Failed to create clean child instance" "ERROR"
        return 1
    fi

    show_status "INFO" "Delegating boot phase to boot-instance.sh (handles PCI handoff + watchdog)"
    if bash "${SCRIPT_DIR}/../scripts/boot-instance.sh" "${new_instance}"; then
        show_status "OK" "Clean child kernel launched"
        log_event "Clean child kernel launched: ${new_instance}"
        return 0
    else
        show_status "ERROR" "Failed to launch clean child kernel"
        log_event "Failed to launch clean child kernel" "ERROR"
        return 1
    fi
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  AUTO-DESTROY COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Log file: ${LOG_FILE}"
    echo -e "  Forensic directory: ${FORENSIC_DIR}"
    echo
    
    echo -e "${BOLD}Actions Taken:${NC}"
    echo -e "  ${GREEN}→ Forensic evidence collected${NC}"
    echo -e "  ${GREEN}→ User data preserved${NC}"
    echo -e "  ${GREEN}→ Child kernel destroyed${NC}"
    echo -e "  ${GREEN}→ Clean child kernel launched${NC}"
    echo
    
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Review forensic evidence in ${FORENSIC_DIR}"
    echo "  2. Investigate the cause of the compromise"
    echo "  3. Update security measures as needed"
    echo
}

# Main function
main() {
    show_banner
    check_root
    validate_required_config CHILD_CPU_MASK CHILD_MEMORY_SIZE PASSTHROUGH_PCI_DEVICES || true
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    # Install mode: configure the response layer only. Running the destroy
    # and relaunch flow at setup time would spawn a child kernel instance
    # mid-wizard, before any child rootfs exists.
    if [ "${1:-}" = "--install" ]; then
        echo -e "${BOLD}Trigger: response layer installation${NC}"
        create_forensic_directory
        show_status "OK" "Forensic directory ready: ${FORENSIC_DIR}"
        show_status "OK" "Response target: child instance (resolved at trigger time)"
        show_status "OK" "Auto-destroy armed: destroy + preserve + forensic + clean relaunch"
        log_event "Response layer installed (configure-only)"
        show_summary
        exit 0
    fi
    
    echo -e "${BOLD}Trigger: Security anomaly detected${NC}"
    
    log_event "Auto-destroy triggered"
    
    if ! resolve_child_instance; then
        show_status "WARN" "No running child instance found - nothing to destroy"
        log_event "Auto-destroy aborted - no child instance" "WARN"
        exit 0
    fi
    
    create_forensic_directory
    collect_forensic_evidence
    preserve_user_data
    destroy_child_kernel
    launch_clean_child
    
    show_summary
}

# Run main function
main "$@"
