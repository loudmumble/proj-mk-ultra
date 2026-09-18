#!/usr/bin/env bash
# probe-pool-ceiling.sh - Find the machine's real maximum contiguous pool size
# SUSPICIOUS Framework: deterministic ceiling discovery
#
# The 112GiB full-zone window failed while a 1GB window succeeded: the real
# ceiling sits somewhere between and only the machine knows it. This probe
# walks candidate sizes from the theoretical maximum downward, submitting a
# baseline at each size, recording success, returning the chunk, and stopping
# at the first success. Output: the ceiling in GB - CHILD_MEMORY_SIZE and
# movablecore follow from it.
#
# Usage: sudo ./probe-pool-ceiling.sh [start-GB] [step-GB]
#   default: start at (ZONE_MOVABLE GB - 4), step down 4GB per attempt.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

MULTIKERNEL_SYSFS="${MULTIKERNEL_SYSFS:-/sys/fs/multikernel}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"
[ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"
# shellcheck source=lib-hardware.sh
. "${SCRIPT_DIR}/lib-hardware.sh"

START_GB="${1:-}"
STEP_GB="${2:-4}"

zone_gb=$(( $(movable_zone_bytes) / 1073741824 ))
if [ -z "${START_GB}" ]; then
    START_GB=$(( zone_gb - 4 ))
fi

phys_ids=$(cpu_phys_ids_from_mask "${CHILD_CPU_MASK:-0xFFFFFFF0}" "$(nproc)") || {
    echo -e "  ${RED}✗ APIC translation failed${NC}"; exit 1
}

mkfs_tmp() {
    cat > /tmp/probe-ceiling.dts << EOFTREE
/dts-v1/;
/ {
    resources {
        cpus = /bits/ 64 <${phys_ids}>;
        memory@0 {
            size = /bits/ 64 <0x$1>;
        };
    };
};
EOFTREE
    dtc -I dts -O dtb -o /tmp/probe-ceiling.dtb /tmp/probe-ceiling.dts 2>/dev/null
}

pool_empty() {
    [ "$(dmesg | grep -c 'Multikernel pool: added')" -le "$(dmesg | grep -c 'Multikernel pool: removed')" ]
}

return_chunk() {
    # return the just-claimed chunk AND the parked CPUs (both must leave the
    # pool or every later attempt hits "Baseline already applied")
    local line base size_hex cpu_nodes="" n=0 full
    line=$(dmesg | grep 'Multikernel pool: added' | tail -1)
    base=$(echo "${line}" | grep -oE '0x[0-9a-f]+' | head -1)
    local mb
    mb=$(echo "${line}" | grep -oE '\([0-9]+ MB\)' | grep -oE '[0-9]+' | head -1)
    size_hex=$(printf '0x%X' $(( ${mb:-0} * 1048576 )))
    local apic
    for apic in $(cpu_phys_ids_from_mask "${CHILD_CPU_MASK:-0xFFFFFFF0}" "$(nproc)"); do
        cpu_nodes+="                cpu@${n} { reg = /bits/ 64 <${apic}>; };\n"
        n=$((n + 1))
    done
    cat > /tmp/probe-return.dts << EOFTREE
/dts-v1/;
/plugin/;
/ {
    fragment@0 {
        target-path = "/resources";
        __overlay__ {
            memory-remove { memory@0 { reg = /bits/ 64 <${base} ${size_hex}>; }; };
            cpu-remove {
${cpu_nodes}            };
        };
    };
};
EOFTREE
    dtc -I dts -O dtb -o /tmp/probe-return.dtb /tmp/probe-return.dts 2>/dev/null && \
        cp /tmp/probe-return.dtb "${MULTIKERNEL_SYSFS}/overlays/new" 2>/dev/null || true
    sleep 1
}

mkdir -p "${MULTIKERNEL_SYSFS}" 2>/dev/null || true
mountpoint -q "${MULTIKERNEL_SYSFS}" || mount -t multikernel none "${MULTIKERNEL_SYSFS}" 2>/dev/null || {
    echo -e "  ${RED}✗ multikernel fs not mountable${NC}"; exit 1
}

# the pool must start empty: return any live chunk first
if ! pool_empty; then
    echo "  pool not empty - returning existing chunk(s) first"
    return_chunk
    sleep 2
fi

echo "ZONE_MOVABLE: ${zone_gb}GB - probing ceiling from ${START_GB}GB, step ${STEP_GB}GB"
echo "---------------------------------------------------------------"

gb="${START_GB}"
ceiling=""
while [ "${gb}" -ge 4 ]; do
    hex=$(printf '%X' $(( gb * 1073741824 )))
    printf '  probing %4d GB ... ' "${gb}"
    if mkfs_tmp "${hex}" && timeout 180 cp /tmp/probe-ceiling.dtb "${MULTIKERNEL_SYSFS}/device_tree" 2>/dev/null; then
        sleep 1
        if dmesg | tail -6 | grep -- "Baseline already applied" > /dev/null; then
            echo -e "${YELLOW}dirty state (EBUSY) - force-cleaning, retrying${NC}"
            return_chunk
            sleep 2
            continue
        fi
        if dmesg | tail -6 | grep -- "Multikernel pool: added" > /dev/null; then
            echo -e "${GREEN}SUCCESS${NC}"
            ceiling="${gb}"
            return_chunk
            sleep 1
            break
        fi
        echo -e "${RED}rejected (true -ENOMEM at this size)${NC}"
    else
        echo -e "${RED}kernel-rejected (EBUSY if pool holds state; ENOMEM at this size)${NC}"
    fi
    # clear any partial state before the next candidate
    if ! pool_empty; then return_chunk; sleep 1; fi
    gb=$(( gb - STEP_GB ))
done

rm -f /tmp/probe-ceiling.dts /tmp/probe-ceiling.dtb /tmp/probe-return.dts /tmp/probe-return.dtb

if [ -n "${ceiling}" ]; then
    echo "---------------------------------------------------------------"
    echo -e "  ${GREEN}CEILING: ${ceiling}GB${NC}"
    echo "  Set: CHILD_MEMORY_SIZE=\"${ceiling}G\" in etc/proj-mk-ultra.conf"
    echo "  Set: movablecore=$(( ceiling + 4 ))G in the boot entry options line"
    echo "  Then: reboot → apply-baseline → spawn → boot-instance"
else
    echo -e "  ${RED}no size succeeded down to 4GB - dmesg names the allocator failure:${NC}"
    dmesg | grep -iE "baseline|contig|pool" | tail -6
    exit 1
fi
