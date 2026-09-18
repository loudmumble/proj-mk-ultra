#!/usr/bin/env bash
# resident-watch.sh - SUSPICIOUS resident anomaly watcher
# Continuously verifies the host kernel stays clean (taint=0) and child
# instance state is sane; triggers the response layer on any violation.
#
# Designed to run under suspicious-watch.service (Restart=always).
# Interval logic is deliberately simple and bounded - this is a watchdog.

set -uo pipefail

TAINT_FILE="/proc/sys/kernel/tainted"
MULTIKERNEL_SYSFS="${MULTIKERNEL_SYSFS:-/sys/fs/multikernel}"
RESPONSE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../response/auto-destroy.sh"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts"
# shellcheck source=../scripts/lib-hardware.sh
. "${LIB_DIR}/lib-hardware.sh"
STATE_DIR="/var/lib/proj-mk-ultra/watch"
INTERVAL="${WATCH_INTERVAL:-5}"
HASH_STATE="${STATE_DIR}/boot-hashes.sha256"

mkdir -p "${STATE_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${STATE_DIR}/watch.log"
}

# Baseline boot-file hashes on first run; on later runs, verify
check_boot_integrity() {
    local current
    current=$(cat /boot/loader/entries/*.conf 2>/dev/null | sha256sum | cut -d' ' -f1)
    [ -n "${current}" ] || return 0

    if [ ! -f "${HASH_STATE}" ]; then
        # Adopt the baseline monitor-boot-integrity established (if it ran
        # first via setup phase 5) so a late-enabled watcher cannot normalize
        # a pre-existing tamper
        local monitor_baseline="/var/lib/proj-mk-ultra/monitoring/boot-hashes.sha256"
        if [ -f "${monitor_baseline}" ]; then
            cp "${monitor_baseline}" "${HASH_STATE}"
            log "Adopted existing baseline from monitor-boot-integrity: $(cat "${HASH_STATE}")"
        else
            echo "${current}" > "${HASH_STATE}"
            log "Baseline boot hash recorded: ${current}"
        fi
        return 0
    fi

    local known
    known=$(cat "${HASH_STATE}")
    if [ "${current}" != "${known}" ]; then
        log "BOOT INTEGRITY VIOLATION: boot entry hash changed (${known} -> ${current})"
        echo "boot-integrity-violation"
        return 1
    fi
    return 0
}

trigger_response() {
    local reason="$1"
    
    # Circuit breaker: prevent infinite destroy-relaunch loop
    local now
    now=$(date +%s)
    local circuit_file="${STATE_DIR}/trigger_times.txt"
    if [ -f "${circuit_file}" ]; then
        # Keep only timestamps from the last 300 seconds (5 minutes)
        awk -v now="${now}" 'now - $1 < 300' "${circuit_file}" > "${circuit_file}.tmp" 2>/dev/null || true
        mv -f "${circuit_file}.tmp" "${circuit_file}" 2>/dev/null || true
    fi
    local count=0
    if [ -f "${circuit_file}" ]; then
        count=$(wc -l < "${circuit_file}" 2>/dev/null || echo 0)
    fi
    if [ "${count}" -ge 3 ]; then
        log "CIRCUIT BREAKER: 3 responses triggered in 5 minutes. Halting auto-response to prevent loop."
        log "Skipped response for: ${reason}"
        return
    fi
    echo "${now}" >> "${circuit_file}"

    log "RESPONSE TRIGGERED: ${reason}"
    if [ -x "${RESPONSE_SCRIPT}" ]; then
        "${RESPONSE_SCRIPT}" 2>&1 | tee -a "${STATE_DIR}/response.log"
    else
        log "Response script missing: ${RESPONSE_SCRIPT}"
    fi
}

log "Resident watch started (interval ${INTERVAL}s, pid $$)"

while true; do
    # Invariant 1: host taint per the documented policy (lib assessment -
    # single implementation shared with FSV-5 and the response layer).
    # Bits 12|13 (out-of-tree/unsigned module on the HOST) trigger the
    # response layer. Bit 18 (TAINT_TEST, the fork's own module marker,
    # kernel/module/main.c:2549) is a documented exception - logged, never
    # responded to. Unexplained bits are logged for review, never auto-destroy.
    read -r taint_status taint_bits <<EOF
$(assess_host_taint)
EOF
    case "${taint_status}" in
        clean)     : ;;
        exception) log "host taint = fork exception (bit 18 TAINT_TEST, bits: ${taint_bits}) - no response" ;;
        unknown)   log "host taint bits unexplained (${taint_bits}) - REVIEW, no auto-response" ;;
        violation) trigger_response "host kernel tainted: out-of-tree/unsigned module (bits: ${taint_bits})" ;;
    esac

    # Invariant 2: boot files unmodified since baseline
    boot_state=$(check_boot_integrity || true)
    if [ "${boot_state}" = "boot-integrity-violation" ]; then
        trigger_response "boot files modified"
    fi

    # Invariant 3: every child instance reports a known status.
    # "ready" (created, resources reserved, awaiting boot) is NORMAL - the
    # create/destroy loop this once caused was: ready -> "abnormal" ->
    # auto-destroy -> auto-relaunch -> ready -> ... forever. An anomaly is a
    # status the core never emits, not a state we haven't booted into yet.
    if [ -d "${MULTIKERNEL_SYSFS}/instances" ]; then
        for inst_dir in "${MULTIKERNEL_SYSFS}/instances/"*; do
            [ -d "${inst_dir}" ] || continue
            status=$(cat "${inst_dir}/status" 2>/dev/null || echo "absent")
            case "${status}" in
                running|ready|absent|exited|stopped) ;;
                *)
                    log "INSTANCE STATE ANOMALY: $(basename "${inst_dir}") status=${status}"
                    trigger_response "instance $(basename "${inst_dir}") abnormal state: ${status}"
                    ;;
            esac
        done
    fi

    sleep "${INTERVAL}"
done
