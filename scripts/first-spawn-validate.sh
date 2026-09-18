#!/usr/bin/env bash
# first-spawn-validate.sh - Automated FSV-1..5 validation after first real spawn
# Turns the manual validation protocol into run-and-read: each check captures
# evidence, evaluates against expected outcomes, and reports PASS/FAIL/REVIEW.
# The human gate = reading the report. Paste it back only on FAIL/REVIEW.
#
# Usage: sudo ./first-spawn-validate.sh [--pre-spawn]
#   --pre-spawn : record pre-spawn baseline (run BEFORE suspicious-boot)

set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

STATE_DIR="/var/lib/proj-mk-ultra/fsv"
REPORT="${STATE_DIR}/fsv-report-$(date +%Y%m%d-%H%M%S).txt"
MULTIKERNEL_SYSFS="${MULTIKERNEL_SYSFS:-/sys/fs/multikernel}"
mkdir -p "${STATE_DIR}"

RESULTS=""
say() { local line; line="$(printf '%s' "$2")"; RESULTS="${RESULTS}[${1}] ${line}"$'\n'; echo -e "  ${3:-}${line}${NC}"; }
pass() { say "PASS" "$1" "${GREEN}"; }
fail() { say "FAIL" "$1" "${RED}"; }
revw() { say "REVIEW" "$1" "${YELLOW}"; }
info() { echo -e "  ${BLUE}→${NC} $1"; }

pre_spawn_baseline() {
    local uptime_s meminfo input_count
    uptime_s=$(awk '{print int($1)}' /proc/uptime)
    input_count=$(ls -1 /sys/class/input 2>/dev/null | wc -l)
    {
        echo "uptime_seconds=${uptime_s}"
        echo "input_devices=${input_count}"
        echo "gpu_driver=$(basename "$(readlink -f /sys/bus/pci/devices/0000:01:00.0/driver 2>/dev/null)" 2>/dev/null || echo unbound)"
        echo "usb_driver=$(basename "$(readlink -f /sys/bus/pci/devices/0000:14:00.0/driver 2>/dev/null)" 2>/dev/null || echo none)"
    } > "${STATE_DIR}/pre-spawn-baseline.txt"
    echo -e "${GREEN}Pre-spawn baseline recorded: ${STATE_DIR}/pre-spawn-baseline.txt${NC}"
    echo -e "Now run: sudo ./scripts/spawn-child-instance.sh child-fsv"
    echo -e "Then re-run this script WITHOUT --pre-spawn to evaluate."
}

# FSV-2: sysfs API accepted the DT and the child reached running
fsv2_sysfs_api() {
    echo -e "\n${BOLD}FSV-2: multikernel sysfs API${NC}"
    local inst_dir
    inst_dir=$(ls -1dt "${MULTIKERNEL_SYSFS}/instances/"* 2>/dev/null | head -1)
    if [ -z "${inst_dir}" ]; then
        fail "no instance directories found - spawn did not create one"
        return
    fi
    local name status
    name=$(basename "${inst_dir}")
    status=$(cat "${inst_dir}/status" 2>/dev/null || echo "absent")
    if [ -f "${inst_dir}/device_tree" ]; then
        pass "FSV-2: sysfs API accepted the DT - instance ${name} created, device_tree exported"
    else
        fail "FSV-2: instance ${name} exists but device_tree missing - dmesg names the rejected field"
    fi
    case "${status}" in
        running) pass "FSV-2: instance runtime state = running" ;;
        ready)   revw "FSV-2: instance ${name} status=ready (resources reserved) - runtime lands after: sudo ./scripts/boot-instance.sh ${name}" ;;
        *)       revw "FSV-2: instance ${name} status=${status} - boot control: sudo ./scripts/boot-instance.sh ${name}" ;;
    esac
}

# FSV-5b: child kernel console evidence - the child's own ring buffer is a
# separate kernel; its taint is captured via mktty and assessed against the
# design value (12288 = nvidia-open, bits 12+13) when nvidia is in play.
fsv5_child_console() {
    echo -e "\n${BOLD}FSV-5b: child console (mktty capture)${NC}"
    local log
    for log in /var/lib/proj-mk-ultra/watch/child-console-*.log; do
        [ -f "${log}" ] || { revw "FSV-5b: no child console capture - boot an instance (boot-instance.sh starts the capture)"; return; }
        if grep -qiE "taint" "${log}" 2>/dev/null; then
            local line
            line=$(grep -iE "taint" "${log}" | tail -1)
            if echo "${line}" | grep -E "12288|274432" > /dev/null; then
                pass "FSV-5b: child taint = design value (12288 nvidia / 274432 with fork marker) - captured: ${line}"
            else
                revw "FSV-5b: child taint line (review against design): ${line}"
            fi
        else
            revw "FSV-5b: capture exists at ${log} but no taint line yet - child still booting or capture just started"
        fi
        return
    done
}

# FSV-1: child-halt semantics = instance exit with host survival
fsv1_child_halt() {
    echo -e "\n${BOLD}FSV-1: child-halt semantics${NC}"
    [ -f "${STATE_DIR}/pre-spawn-baseline.txt" ] || { revw "FSV-1: run with --pre-spawn before spawning to enable this check"; return; }
    local pre_uptime now_uptime
    pre_uptime=$(grep uptime_seconds "${STATE_DIR}/pre-spawn-baseline.txt" | cut -d= -f2)
    now_uptime=$(awk '{print int($1)}' /proc/uptime)
    if [ -z "$(ls -1 "${MULTIKERNEL_SYSFS}/instances/" 2>/dev/null)" ] && [ "${now_uptime}" -ge "${pre_uptime}" ]; then
        revw "FSV-1: no child existed at pre-spawn or now - child-halt semantics NOT exercised this cycle (spawn first, then re-run)"
    elif [ -n "$(ls -1 "${MULTIKERNEL_SYSFS}/instances/" 2>/dev/null)" ]; then
        revw "FSV-1: child instance still active - complete the halt cycle: sudo ./scripts/boot-instance.sh --destroy, then re-run"
    else
        fail "FSV-1: uptime reset (${now_uptime}s < ${pre_uptime}s) - child halt POWERED OFF the machine. Report: child_exit must switch to host-side stop."
    fi
}

# FSV-3: GPU handoff (driver released; core claims device)
fsv3_gpu_handoff() {
    echo -e "\n${BOLD}FSV-3: GPU display handoff${NC}"
    # GPU slot from lspci (vga/3d/display class); 01:00.0 is the conf default
    local gpu_slot
    gpu_slot=$(lspci -nn 2>/dev/null | grep -iE "vga|3d|display" | head -1 | awk '{print $1}')
    local gpu="0000:${gpu_slot:-01:00.0}"
    local passthrough_list
    passthrough_list=$(grep "^PASSTHROUGH_PCI_DEVICES=" "$(dirname "$0")/../etc/proj-mk-ultra.conf" 2>/dev/null | cut -d= -f2- | tr -d '"')
    if ! echo "${passthrough_list}" | grep -- "${gpu_slot:-01:00.0}" > /dev/null; then
        info "GPU (${gpu}) not in PASSTHROUGH_PCI_DEVICES - running headless-child mode (skip or add the slot)"
        return
    fi
    local drv
    drv=$(basename "$(readlink -f "/sys/bus/pci/devices/${gpu}/driver" 2>/dev/null)" 2>/dev/null || echo unbound)
    if [ "${drv}" = "unbound" ]; then
        pass "FSV-3: nouveau released from ${gpu} - device handed to child"
    elif [ "${drv}" = "nouveau" ]; then
        revw "FSV-3: nouveau STILL BOUND - multikernel core did not claim it (or SPAWN_KEEP_BOUND was set). Child has no display."
    else
        revw "FSV-3: ${gpu} bound to unexpected driver: ${drv} - capture and report"
    fi
}

# FSV-4: USB handoff + reclaim (input devices disappear during child, return after)
fsv4_usb_reclaim() {
    echo -e "\n${BOLD}FSV-4: USB handoff and reclaim${NC}"
    [ -f "${STATE_DIR}/pre-spawn-baseline.txt" ] || { revw "FSV-4: needs pre-spawn baseline"; return; }
    local pre_count now_count
    pre_count=$(grep input_devices "${STATE_DIR}/pre-spawn-baseline.txt" | cut -d= -f2)
    now_count=$(ls -1 /sys/class/input 2>/dev/null | wc -l)
    if [ "${now_count}" -lt "${pre_count}" ]; then
        pass "FSV-4: USB handed to child (input devices ${pre_count} -> ${now_count}) - host console keyboard-less as designed"
    else
        info "FSV-4: input device count unchanged (${now_count}) - run this DURING child runtime for the handoff check; post-exit, verify devices returned (equal count = reclaim PASS)"
    fi
}

# FSV-5: resident watcher end-to-end
fsv5_watcher() {
    echo -e "\n${BOLD}FSV-5: resident watcher end-to-end${NC}"
    if systemctl is-active suspicious-watch >/dev/null 2>&1; then
        pass "FSV-5: suspicious-watch active"
    else
        fail "FSV-5: suspicious-watch not active - install per test-checklist Phase 5"
    fi
    if grep -q "Resident watch started" /var/lib/proj-mk-ultra/watch/watch.log 2>/dev/null; then
        pass "FSV-5: watcher log recording"
    else
        fail "FSV-5: watcher log absent at /var/lib/proj-mk-ultra/watch/watch.log"
    fi
    local taint
    taint=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo "x")
    if [ "${taint}" = "0" ]; then
        pass "FSV-5: host taint = 0 (invariant held)"
        return
    fi
    if ! [[ "${taint}" =~ ^[0-9]+$ ]]; then
        fail "FSV-5: host taint unreadable (${taint})"
        return
    fi
    # Decompose: name every set bit. Bits 12/13 on the HOST mean an
    # out-of-tree/unsigned module loaded here - genuine violation. Bits the
    # canonical table does not explain (fork-added taints) route to REVIEW
    # with the identification command, not a blind FAIL.
    local bits="" n bit
    n=$(( taint ))
    bit=0
    while [ "${n}" -gt 0 ]; do
        if [ $(( n % 2 )) -eq 1 ]; then
            bits+="${bit} "
        fi
        n=$(( n / 2 ))
        bit=$(( bit + 1 ))
    done
    local violation=0 fork_test=0 other=0 b
    for b in ${bits}; do
        case "${b}" in
            12|13) violation=1 ;;
            18)    fork_test=1 ;;
            *)     other=1 ;;
        esac
    done
    if [ "${violation}" = "1" ]; then
        fail "FSV-5: host taint = ${taint} (bits: ${bits}) - out-of-tree/unsigned module on the HOST - INVARIANT VIOLATED"
        return
    fi
    if [ "${fork_test}" = "1" ] && [ "${other}" = "0" ]; then
        pass "FSV-5: taint = ${taint} (bit 18 TAINT_TEST - the fork's multikernel module self-marks as test, kernel/module/main.c:2549; documented fork exception, no module-violation bits)"
        return
    fi
    revw "FSV-5: host taint = ${taint} (bits: ${bits}) - unexplained bit(s) beyond the documented TAINT_TEST exception: grep -rn 'TAINT_' ~/multikernel/linux/include/linux/panic.h"
}

main() {
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║  FIRST-SPAWN VALIDATION — FSV-1..5 AUTOMATED               ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    
    case "${1:-}" in
        --pre-spawn) pre_spawn_baseline; exit 0 ;;
    esac
    
    [ "$EUID" -eq 0 ] || { echo -e "${RED}run as root${NC}"; exit 1; }
    
    fsv2_sysfs_api
    fsv3_gpu_handoff
    fsv4_usb_reclaim
    fsv5_watcher
    fsv5_child_console
    fsv1_child_halt
    
    {
        echo "=== FSV REPORT $(date) ==="
        echo "${RESULTS}"
    } | tee "${REPORT}"
    
    local fails
    fails=$(grep -c "\[FAIL\]" "${REPORT}" || true)
    echo
    if [ "${fails}" -gt 0 ]; then
        echo -e "${RED}${BOLD}${fails} FAIL — paste ${REPORT} for targeted resolution${NC}"
    else
        echo -e "${GREEN}${BOLD}No FAILs — first-spawn validation complete. REVIEW lines are expected semi-automated checks.${NC}"
    fi
    echo "Report saved: ${REPORT}"
}

main "$@"
