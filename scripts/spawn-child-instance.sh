#!/usr/bin/env bash
# spawn-child-instance.sh - Spawn child kernel instances
# SUSPICIOUS Framework: Multi-Instance Support
#
# Creates a hardware-isolated child instance via the multikernel overlay API:
#   1. Baseline DTB -> /sys/fs/multikernel/device_tree  (donates the child's
#      CPUs and ZONE_MOVABLE memory to the multikernel pool; skipped when the
#      pool is already populated)
#   2. Instance DTB -> /sys/fs/multikernel/overlays/new (instance-create draws
#      the child's memory and CPUs from that pool)
# Preflights verify the pool's source (movablecore=<child>G reserves the
# memory in ZONE_MOVABLE at host boot).
#
# Usage: sudo ./spawn-child-instance.sh [instance-name]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

FIRST_ARG="${1:-}"
case "${FIRST_ARG}" in
    --check|--dry-run-check)
        INSTANCE_NAME="preflight"
        CHECK_ONLY=true
        ;;
    *)
        INSTANCE_NAME="${FIRST_ARG:-child-$(date +%s)}"
        CHECK_ONLY=false
        ;;
esac
MULTIKERNEL_SYSFS="${MULTIKERNEL_SYSFS:-/sys/fs/multikernel}"
LOG_FILE="${SPAWN_LOG_FILE:-/var/log/proj-mk-ultra/spawn-instance.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

# shellcheck source=lib-hardware.sh
. "${SCRIPT_DIR}/lib-hardware.sh"

CHILD_CPU_MASK="${CHILD_CPU_MASK:-0xFFFFFFF0}"
CHILD_MEMORY_SIZE="${CHILD_MEMORY_SIZE:-112G}"
PASSTHROUGH_PCI_DEVICES="${PASSTHROUGH_PCI_DEVICES:-01:00.0}"

show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         SPAWN CHILD KERNEL INSTANCE                                ║
║         SUSPICIOUS Framework Multi-Instance Support                 ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

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

log_event() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

# Size/mask/kernel-image/APID-translation helpers are shared: scripts/lib-hardware.sh

# Verify the pool's memory source exists: movablecore=<child>G places the
# child's RAM in ZONE_MOVABLE at host boot, and the baseline draws the pool
# from that zone. Without it the host treats those pages as general RAM and
# granting them to the child corrupts both.
# When running INSIDE a child (nested spawn), memory draws from this
# kernel's own allocation instead - the movablecore requirement does not apply.
check_memory_reservation() {
    local child_bytes
    child_bytes=$(size_to_bytes "${CHILD_MEMORY_SIZE}")

    if grep -q "multikernel.role=child" "${PROC_CMDLINE:-/proc/cmdline}" 2>/dev/null; then
        local parent_mem_kb
        parent_mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
        if [ $(( child_bytes / 1024 )) -lt "${parent_mem_kb}" ]; then
            show_status "OK" "Nested spawn: grandchild ${CHILD_MEMORY_SIZE} fits inside this kernel's $(( parent_mem_kb / 1048576 ))GB allocation"
            return 0
        fi
        show_status "ERROR" "Nested spawn: grandchild ${CHILD_MEMORY_SIZE} exceeds this kernel's $(( parent_mem_kb / 1048576 ))GB allocation"
        return 1
    fi

    local movable_bytes
    movable_bytes=$(movable_zone_bytes)

    if [ "${movable_bytes}" -ge "${child_bytes}" ]; then
        show_status "OK" "ZONE_MOVABLE holds $(( movable_bytes / 1073741824 ))GB >= child ${CHILD_MEMORY_SIZE} (movablecore pool source)"
        return 0
    fi

    if [ "${MEMORY_RESERVATION_ACKNOWLEDGED:-false}" = "true" ]; then
        show_status "WARN" "ZONE_MOVABLE short ($(( movable_bytes / 1073741824 ))GB < ${CHILD_MEMORY_SIZE}) - proceeding via MEMORY_RESERVATION_ACKNOWLEDGED=true"
        return 0
    fi

    local child_mib=$(( $(size_to_mib "${CHILD_MEMORY_SIZE}") ))
    local child_gb_ceil=$(( (child_mib + 1023) / 1024 ))
    show_status "ERROR" "ZONE_MOVABLE holds $(( movable_bytes / 1073741824 ))GB but child needs ${CHILD_MEMORY_SIZE}"
    echo ""
    echo -e "${BOLD}The child's pool is carved from ZONE_MOVABLE. Reserve it at host boot:${NC}"
    echo ""
    echo "    movablecore=${child_gb_ceil}G"
    echo ""
    echo -e "${BOLD}Add scan slack - the zone must exceed the child so the contig${NC}"
    echo -e "${BOLD}window can dodge early-userspace pages (window == zone fails):${NC}"
    echo -e "${BOLD}  movablecore=$(( child_gb_ceil + 36 ))G${NC}"
    echo -e "${BOLD}Add to the multikernel boot entry options line, then reboot. Example:${NC}"
    echo -e "${BOLD}options ... intel_iommu=on iommu=pt movablecore=116G nouveau.config=NvGpuRm=1${NC}"
    echo -e "${BOLD}Verify after reboot:${NC} grep -A8 'zone.*Movable' /proc/zoneinfo | grep present"
    echo ""
    echo -e "${BOLD}If your platform reserves memory by another mechanism, set${NC}"
    echo -e "${BOLD}MEMORY_RESERVATION_ACKNOWLEDGED=\"true\" in ${CONFIG_FILE} to override.${NC}"
    return 1
}

check_multikernel_support() {
    echo -e "\n${BOLD}Checking multikernel support...${NC}"

    if ! mountpoint -q "${MULTIKERNEL_SYSFS}" 2>/dev/null; then
        mkdir -p "${MULTIKERNEL_SYSFS}" 2>/dev/null || true
        if ! mount -t multikernel none "${MULTIKERNEL_SYSFS}" 2>/dev/null; then
            show_status "ERROR" "Multikernel filesystem not mountable"
            show_status "INFO" "Run: mount -t multikernel none ${MULTIKERNEL_SYSFS}"
            return 1
        fi
        show_status "OK" "Multikernel filesystem mounted (auto)"
    fi
    show_status "OK" "Multikernel filesystem mounted"

    if [ ! -d "${MULTIKERNEL_SYSFS}/instances" ]; then
        show_status "ERROR" "Instances directory not found under ${MULTIKERNEL_SYSFS}"
        return 1
    fi

    local instances
    instances=$(ls "${MULTIKERNEL_SYSFS}/instances/" 2>/dev/null | wc -l)
    show_status "INFO" "Active instances: ${instances}"

    return 0
}

check_resources() {
    echo -e "\n${BOLD}Checking resource assignment...${NC}"

    validate_required_config CHILD_CPU_MASK CHILD_MEMORY_SIZE PASSTHROUGH_PCI_DEVICES CHILD_ROOT_DEVICE || return 1

    local cpu_count
    cpu_count=$(cpu_count_from_mask "${CHILD_CPU_MASK}")
    show_status "INFO" "Child CPUs: mask ${CHILD_CPU_MASK} (${cpu_count} cores)"

    if [ "${cpu_count}" -lt 2 ]; then
        show_status "WARN" "Child has fewer than 2 CPUs - instance may be slow"
    fi

    show_status "INFO" "Child memory: ${CHILD_MEMORY_SIZE} (ZONE_MOVABLE - verified by check_memory_reservation)"

    local phys_ids
    if ! phys_ids=$(cpu_phys_ids_from_mask "${CHILD_CPU_MASK}"); then
        show_status "ERROR" "Cannot translate ${CHILD_CPU_MASK} to physical APIC IDs (/proc/cpuinfo apicid fields missing)"
        return 1
    fi
    show_status "INFO" "Physical APIC IDs for DTB: ${phys_ids}"

    if [ -z "${CHILD_ROOT_DEVICE:-}" ]; then
        show_status "ERROR" "CHILD_ROOT_DEVICE not set in ${CONFIG_FILE}"
        show_status "INFO" "Run partition-disk.sh first - it persists the child partitions"
        return 1
    fi
    local resolved_root
    resolved_root=$(resolve_child_device "${CHILD_ROOT_DEVICE}")
    if [ ! -b "${resolved_root}" ]; then
        show_status "ERROR" "Child root device not found: ${CHILD_ROOT_DEVICE} (flipped-letter fallback also absent)"
        return 1
    fi
    if [ "${resolved_root}" != "${CHILD_ROOT_DEVICE}" ]; then
        show_status "WARN" "Device letters flipped - child root resolved: ${CHILD_ROOT_DEVICE} → ${resolved_root} (migrate to /dev/disk/by-id/ for stability)"
    fi
    show_status "OK" "Child root device: ${resolved_root}"
    case "${CHILD_ROOT_DEVICE}" in
        /dev/sd?[0-9]|/dev/nvme*n*p[0-9])
            show_status "WARN" "Device letters are not stable across reboots (sda<->sdb flips observed) - prefer /dev/disk/by-id/ paths in CHILD_*_DEVICE" ;;
        /dev/disk/by-id/*) show_status "OK" "Stable by-id device path in use" ;;
    esac

    return 0
}

# Device handoff TIMING: the host-side driver unbind is DEFERRED by default
# (SPAWN_KEEP_BOUND=true) because the reference hardware keeps both the USB
# keyboard AND the USB-attached child root disk on the same controller
# (the USB slot, e.g. 00:14.0 - append it to PASSTHROUGH_PCI_DEVICES for
# USB-root deployments) - an early unbind darkens the operator's input with
# no way back except a hard reset, and the child cannot use the controller
# until its device handoff lands anyway. The multikernel core owns device
# moves at child boot; set SPAWN_KEEP_BOUND=false to force the legacy
# host-side unbind at spawn (hosts that keep their own display/input).
# Fatal-guard: the host root disk and host NIC must NEVER be in the
# passthrough list - the child claiming either destroys the launch-pad
guard_forbidden_slots() {
    # Resolve the host root's PCI slot through the FULL device stack: on
    # LUKS hosts the root is a dm device under /sys/devices/virtual/ with no
    # direct PCI link - walk the slaves chain (dm -> nvme0n1p2 -> nvme0n1)
    # until a device with a PCI parent is reached.
    local root_src base_dev slave root_pci="" nic_slot="" slot
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    [ -n "${root_src}" ] || return 0
    root_src=$(echo "${root_src}" | sed 's/\[.*//')
    base_dev=$(basename "${root_src}")

    for slave in /sys/class/block/${base_dev}/slaves/*; do
        if [ -e "${slave}" ]; then
            base_dev=$(basename "${slave}")
            break
        fi
    done
    # dm devices may chain more than one level - walk until no further slaves
    while [ -d "/sys/class/block/${base_dev}/slaves" ] && \
          [ -n "$(ls -1 /sys/class/block/${base_dev}/slaves 2>/dev/null)" ]; do
        base_dev=$(basename "$(ls -1 "/sys/class/block/${base_dev}/slaves" 2>/dev/null | head -1)")
    done

    root_pci=$(readlink -f "/sys/class/block/${base_dev}/device" 2>/dev/null | \
        awk -F'/pci/devices/' '{print $2}' | cut -d/ -f1 | sed 's/^0000://' || true)

    local iface
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /lo|virbr|docker|veth/ {print $2; exit}')
    if [ -n "${iface}" ]; then
        nic_slot=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null | \
            awk -F'/pci/devices/' '{print $2}' | cut -d/ -f1 | sed 's/^0000://' || true)
    fi

    for slot in ${PASSTHROUGH_PCI_DEVICES}; do
        if [ -n "${root_pci}" ] && [ "${slot}" = "${root_pci}" ]; then
            show_status "ERROR" "REFUSED: host root disk (${root_pci}, via ${base_dev}) is in PASSTHROUGH_PCI_DEVICES - the child would own the launch-pad's root"
            return 1
        fi
        if [ -n "${nic_slot}" ] && [ "${slot}" = "${nic_slot}" ]; then
            show_status "ERROR" "REFUSED: host NIC (${nic_slot}) is in PASSTHROUGH_PCI_DEVICES - the child would own the network hardware"
            return 1
        fi
    done
    show_status "OK" "Passthrough list clean: host root (${root_pci:-unresolved}) and NIC (${nic_slot:-unresolved}) not passed"
    return 0
}

prepare_pci_handoff() {
    if [ "${SPAWN_KEEP_BOUND:-true}" = "true" ]; then
        show_status "OK" "Host driver release DEFERRED (keyboard + USB-attached child root stay live; core owns device moves at boot)"
        return 0
    fi

    local slot driver_path driver_name released=0
    for slot in ${PASSTHROUGH_PCI_DEVICES}; do
        driver_path="/sys/bus/pci/devices/0000:${slot}/driver"
        if [ -L "${driver_path}" ]; then
            driver_name=$(basename "$(readlink "${driver_path}")")
            echo "0000:${slot}" > "${driver_path}/unbind" 2>/dev/null || {
                show_status "WARN" "Could not unbind ${driver_name} from 0000:${slot} (multikernel core may handle bound devices)"
                continue
            }
            show_status "OK" "Released ${driver_name} from 0000:${slot} (host ${slot} display/network dark while child runs)"
            released=$(( released + 1 ))
        fi
    done
    [ "${released}" -gt 0 ] && show_status "INFO" "Devices released to child: ${released}"
    return 0
}

# Donate the child's CPUs and memory to the multikernel pool by writing the
# baseline DTB to /device_tree. Plain DTB (no /plugin wrapper, /resources at
# root, memory@N { size } nodes, physical APIC IDs) - exactly what
# mk_baseline_validate_and_initialize parses. Skipped when the pool is
# already populated; the kernel rejects re-application with EBUSY.
apply_baseline() {
    if pool_populated; then
        show_status "OK" "Multikernel pool already populated - baseline skipped"
        return 0
    fi

    local phys_ids
    phys_ids=$(cpu_phys_ids_from_mask "${CHILD_CPU_MASK}") || {
        show_status "ERROR" "APIC translation failed - cannot build baseline"
        return 1
    }
    local memory_hex
    memory_hex=$(dts_memory_hex "${CHILD_MEMORY_SIZE}")

    local dts_file="/tmp/mk_host_baseline.dts"
    local dtb_file="/tmp/mk_host_baseline.dtb"

    cat > "${dts_file}" << EOFTREE
/dts-v1/;
/ {
    resources {
        cpus = /bits/ 64 <${phys_ids}>;
        memory@0 {
            size = /bits/ 64 <${memory_hex}>;
        };
    };
};
EOFTREE

    # The kernel runs mk_baseline_validate_and_initialize() synchronously inside
    # the write syscall. On a fragmented ZONE_MOVABLE (session already started)
    # this can block for tens of seconds or hang indefinitely - if it hangs, the
    # shell produces NO output and appears to crash. Background the write and
    # poll with a hard timeout so a failure is always surfaced, never a freeze.
    show_status "INFO" "Writing baseline to multikernel pool (may take up to 90s if pool is cold)..."
    local write_rc_file="/run/mk-baseline-write-rc"
    rm -f "${write_rc_file}"
    ( cp "${dtb_file}" "${MULTIKERNEL_SYSFS}/device_tree" 2>/dev/null; echo $? > "${write_rc_file}" ) &
    local write_pid=$!
    local elapsed=0
    while [ "${elapsed}" -lt 90 ]; do
        sleep 1
        elapsed=$(( elapsed + 1 ))
        [ -f "${write_rc_file}" ] && break
        # fast-path: pool appeared before the write even finished
        if pool_populated; then
            show_status "OK" "Pool populated during write (fast-path)"
            wait "${write_pid}" 2>/dev/null || true
            persist_baseline_cpus "${phys_ids}"
            rm -f "${dtb_file}" "${dts_file}" "${write_rc_file}"
            return 0
        fi
    done
    if ! [ -f "${write_rc_file}" ]; then
        kill "${write_pid}" 2>/dev/null || true
        show_status "ERROR" "Baseline write timed out after 90s - ZONE_MOVABLE is fragmented."
        show_status "INFO" "Root cause: mk-baseline.service must run at boot BEFORE the user session pins pages."
        show_status "INFO" "Fix: sudo systemctl enable mk-baseline.service && reboot (then spawn again)"
        dmesg | tail -6 | sed 's/^/    /'
        rm -f "${dtb_file}" "${dts_file}" "${write_rc_file}"
        return 1
    fi
    local write_rc
    write_rc=$(cat "${write_rc_file}")
    rm -f "${write_rc_file}"
    if [ "${write_rc}" != "0" ]; then
        if dmesg | tail -30 | grep -- "Baseline already applied" > /dev/null; then
            show_status "OK" "Pool was populated concurrently - baseline skipped"
            rm -f "${dtb_file}" "${dts_file}"
            return 0
        fi
        show_status "ERROR" "Baseline write failed - recent kernel messages:"
        dmesg | tail -6 | sed 's/^/    /'
        rm -f "${dtb_file}" "${dts_file}"
        return 1
    fi
    rm -f "${dtb_file}" "${dts_file}"

    if pool_populated; then
        show_status "OK" "Baseline applied - pool populated (${CHILD_MEMORY_SIZE} + ${CHILD_CPU_MASK})"
        persist_baseline_cpus "${phys_ids}"
        log_event "Baseline applied: ${CHILD_MEMORY_SIZE}, ${CHILD_CPU_MASK}"
        return 0
    fi
    show_status "ERROR" "Baseline written but pool not detected - kernel messages:"
    dmesg | tail -6 | sed 's/^/    /'
    return 1
}

create_instance() {
    echo -e "\n${BOLD}Creating child instance: ${INSTANCE_NAME}${NC}"

    log_event "Spawning instance: ${INSTANCE_NAME}"

    local instance_dir="${MULTIKERNEL_SYSFS}/instances/${INSTANCE_NAME}"

    if [ -d "${instance_dir}" ]; then
        show_status "WARN" "Instance already exists: ${INSTANCE_NAME}"
        return 1
    fi

    local phys_ids
    phys_ids=$(cpu_phys_ids_from_mask "${CHILD_CPU_MASK}") || {
        show_status "ERROR" "APIC translation failed - cannot build instance DTB"
        return 1
    }
    
    local avail_bytes=0
    if [ -f "${MULTIKERNEL_SYSFS}/pool_available" ]; then
        avail_bytes=$(cat "${MULTIKERNEL_SYSFS}/pool_available" 2>/dev/null || echo "0")
    else
        local iomem_line=$(grep -iE "multikernel.*pool" /proc/iomem | head -1)
        if [ -n "$iomem_line" ]; then
            local start_hex=$(echo "$iomem_line" | cut -d'-' -f1 | tr -d ' ')
            local end_hex=$(echo "$iomem_line" | cut -d'-' -f2 | cut -d' ' -f1)
            avail_bytes=$(( 0x${end_hex} - 0x${start_hex} + 1 ))
        fi
    fi
    local requested_bytes=$(size_to_bytes "${CHILD_MEMORY_SIZE}")
    local margin=2097152 # 2MiB margin
    local memory_hex
    if [ "${avail_bytes}" -gt "${margin}" ] && [ "${requested_bytes}" -gt "$(( avail_bytes - margin ))" ]; then
        memory_hex=$(printf '0x%X' $(( avail_bytes - margin )))
        show_status "INFO" "Adjusted memory request to fit available pool (size: ${memory_hex})"
    else
        memory_hex=$(dts_memory_hex "${CHILD_MEMORY_SIZE}")
    fi

    local kernel_path initrd_path
    kernel_path=$(find_child_kernel) || {
        show_status "WARN" "Multikernel kernel image not located - instance relies on core-loaded image"
        kernel_path=""
    }
    if [ -n "${kernel_path}" ]; then
        initrd_path=$(find_child_initrd "${kernel_path}") || initrd_path=""
        show_status "INFO" "Kernel: ${kernel_path}"
        [ -n "${initrd_path}" ] && show_status "INFO" "Initrd: ${initrd_path}"
    fi

    local dts_file="/tmp/mk_child_instance.dts"
    local dtb_file="/tmp/mk_child_instance.dtb"

    local extra_nodes=""
    if [ -n "${kernel_path}" ]; then
        extra_nodes+="kernel = \"${kernel_path}\";\n                "
    fi
    if [ -n "${initrd_path}" ]; then
        extra_nodes+="initrd = \"${initrd_path}\";\n                "
    fi
    if [ -n "${CHILD_ROOT_DEVICE:-}" ]; then
        local resolved_root=$(resolve_child_device "${CHILD_ROOT_DEVICE}")
        local root_arg="${resolved_root}"
        local partuuid=$(blkid -s PARTUUID -o value "${resolved_root}" 2>/dev/null || true)
        if [ -n "${partuuid}" ]; then
            root_arg="PARTUUID=${partuuid}"
        fi
        extra_nodes+="bootargs = \"root=${root_arg} rw multikernel.role=child\";\n                "
    fi

    cat > "${dts_file}" << EOFTREE
/dts-v1/;
/plugin/;
/ {
    fragment@0 {
        target-path = "/instances";
        __overlay__ {
            instance-create {
                instance-name = "${INSTANCE_NAME}";
                ${extra_nodes}resources {
                    memory-bytes = /bits/ 64 <${memory_hex}>;
                    cpus = /bits/ 64 <${phys_ids}>;
                };
            };
        };
    };
};
EOFTREE

    # Compile and submit through the overlay transaction system
    if ! dtc -I dts -O dtb -o "${dtb_file}" "${dts_file}" 2>/dev/null; then
        show_status "ERROR" "dtc failed to compile instance DTS"
        return 1
    fi
    show_status "OK" "Instance DTB compiled: $(wc -c < "${dtb_file}") bytes"

    show_status "INFO" "Submitting instance overlay"
    cp "${dtb_file}" "${MULTIKERNEL_SYSFS}/overlays/new" 2>/dev/null || true
    
    local waited=0
    while [ "${waited}" -lt 45 ]; do
        sleep 1
        waited=$(( waited + 1 ))
        if [ -d "${instance_dir}" ]; then
            show_status "OK" "Instance created: ${instance_dir} (memory bytes: ${memory_hex})"
            log_event "Instance ${INSTANCE_NAME} created (memory bytes: ${memory_hex}, ${CHILD_CPU_MASK})"
            rm -f "${dtb_file}" "${dts_file}"
            return 0
        fi
        local tx_newest=$(ls -1dt "${MULTIKERNEL_SYSFS}/overlays/"tx_* 2>/dev/null | head -1)
        if [ -n "${tx_newest}" ] && grep -q "failed" "${tx_newest}/status" 2>/dev/null; then
            break
        fi
    done

    show_status "ERROR" "Reservation failed - kernel messages:"
    dmesg | tail -10 | sed 's/^/    /'
    rm -f "${dtb_file}" "${dts_file}"
    return 1
}

show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  INSTANCE CREATED${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"

    echo -e "  Instance name: ${INSTANCE_NAME}"
    echo -e "  CPUs: ${CHILD_CPU_MASK} | Memory: ${CHILD_MEMORY_SIZE} | PCI: ${PASSTHROUGH_PCI_DEVICES}"
    echo -e "  Root: ${CHILD_ROOT_DEVICE}"
    echo -e "  Log file: ${LOG_FILE}"
    echo

    echo -e "${BOLD}Next Steps:${NC}"
    echo -e "  1. Monitor: watch ${MULTIKERNEL_SYSFS}/instances/${INSTANCE_NAME}/status"
    echo -e "  2. Boot it: sudo ./scripts/boot-instance.sh ${INSTANCE_NAME}"
    echo -e "  3. Host console loses USB while ${PASSTHROUGH_PCI_DEVICES} is passed through"
    echo
}

main() {
    show_banner
    check_root

    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    echo -e "${BOLD}Target instance: ${INSTANCE_NAME}${NC}"

    check_multikernel_support || exit 1
    check_memory_reservation || exit 1
    check_resources || exit 1

    if [ "${CHECK_ONLY}" = "true" ]; then
        show_status "OK" "All spawn preflight checks passed (no instance created)"
        exit 0
    fi

    guard_forbidden_slots || exit 1
    apply_baseline || exit 1
    prepare_pci_handoff || exit 1
    create_instance || exit 1
    show_summary
}

main "$@"
