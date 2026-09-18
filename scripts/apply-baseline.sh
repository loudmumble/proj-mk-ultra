#!/usr/bin/env bash
# apply-baseline.sh - Apply the multikernel baseline at boot
# SUSPICIOUS Framework: deterministic boot-time boundary establishment
#
# Donates the child's CPUs and ZONE_MOVABLE memory to the multikernel pool
# by writing the baseline DTB to /sys/fs/multikernel/device_tree. Runs BEFORE
# the desktop session (mk-baseline.service: Before=multi-user.target) while
# the movable zone holds no pinned pages - the pool chunk equals the whole
# zone, so any pinned page after session start would defeat the contig
# allocation. Idempotent: exits 0 when the pool is already populated.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

MULTIKERNEL_SYSFS="${MULTIKERNEL_SYSFS:-/sys/fs/multikernel}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

# shellcheck source=lib-hardware.sh
. "${SCRIPT_DIR}/lib-hardware.sh"

CHILD_CPU_MASK="${CHILD_CPU_MASK:-0xFFFFFFF0}"
CHILD_MEMORY_SIZE="${CHILD_MEMORY_SIZE:-112G}"

fail() {
    echo -e "  ${RED}✗ mk-baseline: $1${NC}" >&2
    exit 1
}

ok() {
    echo -e "  ${GREEN}✓ mk-baseline: $1${NC}"
}

pool_populated() {
    [ "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: added')" -gt "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: removed')" ]
}

if pool_populated; then
    ok "pool already populated - nothing to do"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    fail "must run as root (systemd unit provides this)"
fi

mkdir -p "${MULTIKERNEL_SYSFS}" 2>/dev/null || true
if ! mountpoint -q "${MULTIKERNEL_SYSFS}"; then
    mnt_err=""
    for attempt in 1 2 3; do
        mnt_err=$(mount -t multikernel none "${MULTIKERNEL_SYSFS}" 2>&1) && break
        sleep 2
    done
    if ! mountpoint -q "${MULTIKERNEL_SYSFS}"; then
        fail "multikernel filesystem not mountable after 3 attempts: ${mnt_err}"
    fi
fi

if [ ! -d "${MULTIKERNEL_SYSFS}/instances" ]; then
    fail "instances directory missing under ${MULTIKERNEL_SYSFS} - kernel lacks CONFIG_MULTIKERNEL"
fi

phys_ids=$(cpu_phys_ids_from_mask "${CHILD_CPU_MASK}") || {
    fail "APIC translation failed for ${CHILD_CPU_MASK} - cannot build baseline"
}
memory_hex=$(dts_memory_hex "${CHILD_MEMORY_SIZE}")

dts_file="/run/mk-host-baseline.dts"
dtb_file="/run/mk-host-baseline.dtb"

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

dtc -I dts -O dtb -o "${dtb_file}" "${dts_file}" 2>/dev/null || \
    fail "dtc failed to compile baseline DTS (is dtc installed?)"

# Background the write: the kernel runs the full baseline allocation inside the
# write syscall. Even at early boot this can take a few seconds; make sure
# journalctl always sees a clean exit/fail line rather than a hung service.
write_rc_file="/run/mk-baseline-write-rc"
rm -f "${write_rc_file}"
( cp "${dtb_file}" "${MULTIKERNEL_SYSFS}/device_tree" 2>/dev/null; echo $? > "${write_rc_file}" ) &
write_pid=$!
elapsed=0
while [ "${elapsed}" -lt 120 ]; do
    sleep 1
    elapsed=$(( elapsed + 1 ))
    [ -f "${write_rc_file}" ] && break
    pool_populated && {
        ok "pool populated during write (fast-path)"
        wait "${write_pid}" 2>/dev/null || true
        persist_baseline_cpus "${phys_ids}"
        rm -f "${dts_file}" "${dtb_file}" "${write_rc_file}"
        exit 0
    }
done
if ! [ -f "${write_rc_file}" ]; then
    kill "${write_pid}" 2>/dev/null || true
    fail "baseline write timed out after 120s - ZONE_MOVABLE fragmented or kernel hung"
fi
write_rc=$(cat "${write_rc_file}")
rm -f "${write_rc_file}"
if [ "${write_rc}" != "0" ]; then
    if dmesg | tail -30 | grep -- "Baseline already applied" > /dev/null; then
        ok "pool was populated concurrently - baseline skipped"
        rm -f "${dts_file}" "${dtb_file}"
        exit 0
    fi
    fail "baseline write rejected - kernel messages follow"
fi
rm -f "${dts_file}" "${dtb_file}"

if pool_populated; then
    persist_baseline_cpus "${phys_ids}"
    ok "baseline applied - pool holds ${CHILD_MEMORY_SIZE} + ${CHILD_CPU_MASK}"
    exit 0
fi
fail "baseline written but pool not detected - kernel messages follow"
