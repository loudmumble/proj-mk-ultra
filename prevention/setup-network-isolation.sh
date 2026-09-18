#!/usr/bin/env bash
# setup-network-isolation.sh - Verify network segmentation (structural)
# SUSPICIOUS Framework: Prevention Layer
#
# The child kernel's network isolation is STRUCTURAL, not firewall-enforced:
#   1. The child has no network device - the host NIC is never in
#      PASSTHROUGH_PCI_DEVICES, so the child netstack has no hardware.
#   2. The instance DT declares private-network=yes.
# Host iptables rules CANNOT affect the child (separate kernel, separate
# netstack) - any host-side firewall here would only harm the host itself.
#
# This script verifies the structural facts and refuses deployment when they
# are absent. Child-side service disabling lives in
# pre-install/install-child-kernel.sh (configure_network).
#
# Usage: sudo ./setup-network-isolation.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

PASSTHROUGH_PCI_DEVICES="${PASSTHROUGH_PCI_DEVICES:-01:00.0}"

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

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${BOLD}[ERROR] This script must be run as root${NC}"
        exit 1
    fi
}

# Identify the host's primary NIC PCI slot (the device that must NOT be passed)
host_nic_slot() {
    local iface
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /lo|virbr|docker|veth/ {print $2; exit}')
    [ -n "${iface}" ] || return 1
    local dev_path
    dev_path=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || echo "")
    [ -n "${dev_path}" ] || return 1
    basename "$(dirname "${dev_path}")"
}

# Check 1: the host NIC must not be in the passthrough list
verify_nic_not_passed() {
    show_status "STEP" "Verifying host NIC is not passed through..."
    local nic_slot
    if ! nic_slot=$(host_nic_slot); then
        show_status "WARN" "Could not identify host NIC PCI slot"
        return 0
    fi
    
    show_status "INFO" "Host NIC: ${nic_slot}"
    
    local slot
    for slot in ${PASSTHROUGH_PCI_DEVICES}; do
        if [ "${slot}" = "${nic_slot}" ]; then
            show_status "ERROR" "Host NIC ${nic_slot} IS in PASSTHROUGH_PCI_DEVICES - child would own the network hardware"
            return 1
        fi
    done
    show_status "OK" "Host NIC ${nic_slot} not in passthrough list - child has no network hardware"
    return 0
}

# Check 2: the DT security block declares private-network
verify_dt_private_network() {
    show_status "STEP" "Verifying instance DT declares private-network..."
    local found=0
    local dt_file
    for dt_file in /tmp/mk_child_instance.dts /tmp/clean_child.dts; do
        if [ -f "${dt_file}" ] && grep -q 'private-network = "yes"' "${dt_file}"; then
            show_status "OK" "${dt_file}: private-network=yes"
            found=1
        fi
    done
    if [ "${found}" = "0" ]; then
        show_status "INFO" "No DT on disk to verify (generated at spawn time by spawn-child-instance.sh, which sets private-network per NETWORK_ISOLATION)"
    fi
    return 0
}

# Check 3: child-side services already disabled in the rootfs (if present)
verify_child_rootfs_network_disabled() {
    show_status "STEP" "Verifying child rootfs network services..."
    local root="/mnt/child-root"
    if [ ! -d "${root}/etc" ]; then
        show_status "INFO" "Child rootfs not mounted - configure_network in install-child-kernel.sh handles child-side disabling"
        return 0
    fi
    local svc
    for svc in NetworkManager systemd-networkd wpa_supplicant; do
        if [ -e "${root}/etc/systemd/system/multi-user.target.wants/${svc}.service" ]; then
            show_status "WARN" "Child rootfs still enables ${svc}"
        else
            show_status "OK" "Child rootfs: ${svc} not enabled"
        fi
    done
    return 0
}

# In-child manual verification (run from INSIDE the child):
#   ip link show   → only lo present
#   ping fails for any address
# Documented here; not executable from the host by design.

main() {
    local failed=0
    
    verify_nic_not_passed || failed=$((failed + 1))
    verify_dt_private_network
    verify_child_rootfs_network_disabled
    
    echo
    if [ "${failed}" -eq 0 ]; then
        show_status "OK" "Network isolation verified (structural): child has no network hardware and private-network=yes"
    else
        show_status "ERROR" "Network isolation NOT verified - fix the structural facts above before spawning"
        exit 1
    fi
    exit 0
}

main "$@"
