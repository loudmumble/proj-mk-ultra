#!/usr/bin/env bash
# suspicious-boot.sh - Boot selector for PROJ-MK-ULTRA
# SUSPICIOUS Framework: Utility Script
#
# Interactive menu for managing kernel instances and running audits.
# Intended to be symlinked to /usr/local/bin/suspicious-boot.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MULTIKERNEL_SYSFS="/sys/fs/multikernel"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

# shellcheck source=lib-hardware.sh
. "${SCRIPT_DIR}/lib-hardware.sh"

show_status() {
    local status="$1"
    local message="$2"
    case "${status}" in
        OK)    echo -e "  ${GREEN}✓${NC} ${message}" ;;
        WARN)  echo -e "  ${YELLOW}⚠${NC} ${message}" ;;
        ERROR) echo -e "  ${RED}✗${NC} ${message}" ;;
        INFO)  echo -e "  ${BLUE}→${NC} ${message}" ;;
    esac
}

# --- Option 1: Launch agent kernel via spawn-child-instance.sh ---
launch_instance() {
    echo -e "\n${BOLD}Launching agent kernel instance...${NC}"

    if [ ! -d "${MULTIKERNEL_SYSFS}" ]; then
        show_status "ERROR" "Multikernel filesystem not mounted"
        show_status "INFO" "Run: mount -t multikernel none ${MULTIKERNEL_SYSFS}"
        return 1
    fi

    local instance_name="child-$(date +%s)"
    show_status "INFO" "Instance name: ${instance_name}"

    if [ -x "${SCRIPT_DIR}/spawn-child-instance.sh" ]; then
        bash "${SCRIPT_DIR}/spawn-child-instance.sh" "${instance_name}"
    else
        show_status "ERROR" "spawn-child-instance.sh not found or not executable"
        return 1
    fi
}

# --- Option 2: Stop agent instance via multikernel sysfs control ---
stop_instance() {
    echo -e "\n${BOLD}Stopping agent kernel instance...${NC}"

    if [ ! -d "${MULTIKERNEL_SYSFS}/instances" ]; then
        show_status "ERROR" "Multikernel instances directory not found"
        return 1
    fi

    # List running instances (exclude host)
    local instances=()
    while IFS= read -r inst; do
        local role
        role=$(cat "${MULTIKERNEL_SYSFS}/instances/${inst}/role" 2>/dev/null || echo "unknown")
        if [ "${role}" != "host" ]; then
            instances+=("${inst}")
        fi
    done < <(ls "${MULTIKERNEL_SYSFS}/instances/" 2>/dev/null)

    if [ ${#instances[@]} -eq 0 ]; then
        show_status "WARN" "No child instances running"
        return 0
    fi

    echo -e "\n${BOLD}Running child instances:${NC}"
    for i in "${!instances[@]}"; do
        local inst="${instances[$i]}"
        local status
        status=$(cat "${MULTIKERNEL_SYSFS}/instances/${inst}/status" 2>/dev/null || echo "unknown")
        echo "  $((i+1))) ${inst} (status: ${status})"
    done
    echo "  a) Stop ALL instances"
    echo "  0) Cancel"
    echo

    read -p "Select instance to stop: " selection

    if [ "${selection}" = "0" ]; then
        return 0
    fi

    stop_selected_instance() {
        local target="$1"
        show_status "INFO" "Sending shutdown to ${target}..."

        # Graceful shutdown first (matches auto-destroy.sh pattern)
        echo "shutdown" > "${MULTIKERNEL_SYSFS}/instances/${target}/control" 2>/dev/null || true

        # Wait up to 10 seconds for graceful shutdown
        local waited=0
        while [ ${waited} -lt 10 ]; do
            if [ ! -d "${MULTIKERNEL_SYSFS}/instances/${target}" ]; then
                show_status "OK" "Instance ${target} shut down gracefully"
                return 0
            fi
            sleep 1
            waited=$((waited + 1))
        done

        # Force shutdown if graceful failed
        show_status "WARN" "Graceful shutdown timed out, forcing..."
        echo "force-shutdown" > "${MULTIKERNEL_SYSFS}/instances/${target}/control" 2>/dev/null || true
        sleep 2

        # Overlay-based removal (verified mechanism) as the final fallback
        if [ -d "${MULTIKERNEL_SYSFS}/instances/${target}" ]; then
            mk_remove_instance_overlay "${target}" || true
        fi

        if [ ! -d "${MULTIKERNEL_SYSFS}/instances/${target}" ]; then
            show_status "OK" "Instance ${target} force-shutdown"
        else
            show_status "ERROR" "Failed to stop ${target}"
        fi
    }

    if [ "${selection}" = "a" ] || [ "${selection}" = "A" ]; then
        for inst in "${instances[@]}"; do
            stop_selected_instance "${inst}"
        done
    elif [[ "${selection}" =~ ^[0-9]+$ ]] && [ "${selection}" -ge 1 ] && [ "${selection}" -le ${#instances[@]} ]; then
        stop_selected_instance "${instances[$((selection-1))]}"
    else
        show_status "ERROR" "Invalid selection"
        return 1
    fi
}

# --- Main menu ---
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    S U S P I C I O U S   B O O T   S E L E C T O R          ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo

echo "Current Kernel: $(uname -r)"
echo

# Show current instance count if multikernel is available
if [ -d "${MULTIKERNEL_SYSFS}/instances" ]; then
    count=$(ls "${MULTIKERNEL_SYSFS}/instances/" 2>/dev/null | wc -l)
    echo "Active Instances: ${count}"
fi
echo

echo "Select an option:"
echo
echo "  1) Launch Agent Kernel Instance"
echo "     Create isolated kernel for agent execution"
echo
echo "  2) Stop Agent Kernel Instance"
echo "     Shutdown and reclaim resources"
echo
echo "  3) Run Security Audit"
echo "     Verify SUSPICIOUS Framework invariants"
echo
echo "  4) View Instance Status"
echo "     Detailed status of all instances"
echo
echo "  5) Reboot into Host Kernel"
echo "     Standard user operations"
echo
echo "  6) Reboot into Agent Kernel"
echo "     Optimized for agent execution"
echo
echo "  0) Exit"
echo

read -p "Select option (0-6): " choice

case $choice in
    1)
        launch_instance
        ;;
    2)
        stop_instance
        ;;
    3)
        echo "Running security audit..."
        bash "${SCRIPT_DIR}/security-audit.sh"
        ;;
    4)
        echo -e "\n${BOLD}Instance Status:${NC}"
        if [ -d "${MULTIKERNEL_SYSFS}/instances" ]; then
            for inst in "${MULTIKERNEL_SYSFS}/instances/"*/; do
                if [ -d "${inst}" ]; then
                    local_name=$(basename "${inst}")
                    local_role=$(cat "${inst}/role" 2>/dev/null || echo "unknown")
                    local_status=$(cat "${inst}/status" 2>/dev/null || echo "unknown")
                    echo -e "  ${BOLD}${local_name}${NC}: role=${local_role}, status=${local_status}"
                fi
            done
        else
            echo "  No instances directory found"
        fi
        ;;
    5)
        echo "Rebooting into host (non-multikernel) kernel..."
        # Select the first bootloader entry that does NOT contain multikernel/mk2
        host_entry=$(bootctl list --no-pager 2>/dev/null | grep "^  id:" | grep -viE "multikernel|mk2" | head -1 | awk '{print $2}')
        if [ -n "${host_entry}" ]; then
            bootctl set-oneshot "${host_entry}" && echo "  → One-shot boot entry set: ${host_entry}" && sudo reboot
        else
            echo "  ⚠ No non-multikernel entry found in bootloader — rebooting to default"
            sudo reboot
        fi
        ;;
    6)
        echo "Rebooting into multikernel (agent) kernel..."
        mk_entry=$(bootctl list --no-pager 2>/dev/null | grep "^  id:" | grep -iE "multikernel|mk2" | head -1 | awk '{print $2}')
        if [ -n "${mk_entry}" ]; then
            bootctl set-oneshot "${mk_entry}" && echo "  → One-shot boot entry set: ${mk_entry}" && sudo reboot
        else
            echo "  ⚠ No multikernel entry found in bootloader — check /boot/loader/entries/"
        fi
        ;;
    0)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo "Invalid option"
        ;;
esac
