#!/usr/bin/env bash
# boot-instance.sh - Boot/stop multikernel child instances
# SUSPICIOUS Framework: instance runtime control
#
# Boot: detects the instance's control interface from the kernel-created
# files (control file present -> documented commands, tried in order with
# status verification between attempts; a dedicated boot/spawn/start file
# -> single write), then polls status to running. Stop: shutdown via
# control, then the verified instance-remove overlay as the fallback.
#
# Usage: sudo ./boot-instance.sh [instance-name]        # boot to running
#        sudo ./boot-instance.sh --destroy [instance]   # stop + remove
#        sudo ./boot-instance.sh --list                 # show instances

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

MULTIKERNEL_SYSFS="${MULTIKERNEL_SYSFS:-/sys/fs/multikernel}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"
if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi
# shellcheck source=lib-hardware.sh
. "${SCRIPT_DIR}/lib-hardware.sh"

MODE="boot"

# Run log: every status line appends here (show_status writes it) - survives
# the run without hijacking stdout (the exec-tee pattern could exit silently
# before printing anything when the process-substitution setup failed).
BOOT_LOG="/var/lib/proj-mk-ultra/watch/boot-instance-current.log"
mkdir -p "$(dirname "${BOOT_LOG}")"
TARGET="${1:-}"
case "${TARGET}" in
    --destroy) MODE="destroy"; TARGET="${2:-}" ;;
    --list)    MODE="list" ;;
esac

show_status() {
    local s="$1" m="$2"
    local line="[$(date '+%H:%M:%S')] ${s}: ${m}"
    echo "${line}" >> "${BOOT_LOG}" 2>/dev/null || true
    case "${s}" in
        OK)    echo -e "  ${GREEN}✓${NC} ${m}" ;;
        WARN)  echo -e "  ${YELLOW}⚠${NC} ${m}" ;;
        ERROR) echo -e "  ${RED}✗${NC} ${m}" ;;
        INFO)  echo -e "  → ${m}" ;;
    esac
}

die() { show_status "ERROR" "$1"; exit 1; }

instance_status() {
    cat "${MULTIKERNEL_SYSFS}/instances/$1/status" 2>/dev/null || echo "absent"
}

pick_instance() {
    local name="${TARGET:-}"
    if [ -n "${name}" ] && [ -d "${MULTIKERNEL_SYSFS}/instances/${name}" ]; then
        echo "${name}"
        return 0
    fi
    local newest
    newest=$(ls -1dt "${MULTIKERNEL_SYSFS}/instances/"* 2>/dev/null | head -1)
    [ -n "${newest}" ] || return 1
    basename "${newest}"
}


# Stream the child kernel's console to the host log via /dev/mktty - the
# inter-kernel channel this kernel provides. The child's ring buffer is
# otherwise invisible to host dmesg; this capture closes the gap so the
# resident watcher's log covers both kernels.
start_console_capture() {
    local name="$1"
    local id
    id=$(cat "${MULTIKERNEL_SYSFS}/instances/${name}/id" 2>/dev/null) || return 1
    local logdir="/var/lib/proj-mk-ultra/watch"
    mkdir -p "${logdir}"
    local log="${logdir}/child-console-${name}.log"
    local pidfile="${logdir}/child-console-${name}.pid"
    : > "${log}"
    nohup bash -c "exec 3<>/dev/mktty; printf '%s\\n' '${id}' >&3; sleep 1; exec cat <&3 >> '${log}'" >/dev/null 2>&1 &
    echo $! > "${pidfile}"
    show_status "INFO" "child console capturing to ${log} (instance id ${id})"
}

stop_console_capture() {
    local name="$1"
    local pidfile="/var/lib/proj-mk-ultra/watch/child-console-${name}.pid"
    if [ -f "${pidfile}" ]; then
        kill "$(cat "${pidfile}")" 2>/dev/null || true
        rm -f "${pidfile}"
        show_status "INFO" "child console capture stopped"
    fi
}

# Child taint assessment: nvidia-open in the child taints 12288 by design
# (bits 12+13 out-of-tree+unsigned, GPL-compatible - host stays clean). Any
# other value routes to review with the captured console as evidence.
assess_child_taint() {
    local name="$1"
    local log="/var/lib/proj-mk-ultra/watch/child-console-${name}.log"
    [ -f "${log}" ] || return 0
    sleep 2
    if grep -qi "nvidia" "${log}"; then
        show_status "INFO" "child: nvidia modules detected - expected taint 12288 (+262144 fork marker = 274432 if the fork module also loads)"
    fi
    local line
    line=$(grep -iE "taint" "${log}" | tail -1)
    if [ -n "${line}" ]; then
        if echo "${line}" | grep -E "12288|274432" > /dev/null; then
            show_status "OK" "child taint = design value (12288 nvidia-open / 274432 with the fork test marker, captured via mktty)"
        else
            show_status "WARN" "child taint line (review against design): ${line}"
        fi
    else
        show_status "INFO" "no child taint line captured yet - child may still be booting"
    fi
}

list_instances() {
    echo -e "${BOLD}Instances:${NC}"
    local d
    for d in "${MULTIKERNEL_SYSFS}/instances/"*; do
        [ -d "${d}" ] || continue
        printf "  %-24s status=%s\n" "$(basename "${d}")" "$(instance_status "$(basename "${d}")")"
    done
}

do_boot() {
    local name
    name=$(pick_instance) || die "no instance found - spawn one first (spawn-child-instance.sh)"

    # Guard: refuse when OTHER instances already hold pool resources - the
    # boot handoff moves real peripherals; a second instance colliding with
    # a live one can take the host down. One active child at a time.
    local other
    other=$(ls -1 "${MULTIKERNEL_SYSFS}/instances/" 2>/dev/null | grep -v "^${name}$" | head -1 || true)
    if [ -n "${other}" ]; then
        die "another instance holds pool resources: ${other} - destroy it first: sudo ./scripts/boot-instance.sh --destroy ${other}"
    fi
    local dir="${MULTIKERNEL_SYSFS}/instances/${name}"

    local status
    status=$(instance_status "${name}")
    if [ "${status}" = "running" ]; then
        show_status "OK" "instance ${name} already running"
        return 0
    fi
    show_status "INFO" "instance ${name} status=${status} - booting"

    local interface="none"
    if [ -f "${dir}/control" ]; then
        interface="control"
    elif [ -f "${dir}/boot" ]; then
        interface="boot"
    elif [ -f "${dir}/spawn" ]; then
        interface="spawn"
    elif [ -f "${dir}/start" ]; then
        interface="start"
    fi
    show_status "INFO" "control interface: ${interface} (files: $(ls "${dir}" 2>/dev/null | tr '\n' ' '))"

    # Operator channel check: handed-off devices (GPU, and the USB controller
    # when listed) leave the host display-less and/or keyboard-less while the
    # child runs - SSH is the only control channel. Verify BEFORE handing off.
    if ! systemctl is-active --quiet ssh 2>/dev/null && ! systemctl is-active --quiet sshd 2>/dev/null; then
        show_status "WARN" "host SSH inactive - you will have NO control while the child runs (GPU handoff also darkens the host display)"
    fi

    # ---- Peripheral handoff: move PASSTHROUGH_PCI_DEVICES into the child,
    # then release the host drivers at the boot instant. The move uses the
    # kernel's documented instance device-add overlay (target /instances/<name>).
    local pci_list
    local pci_list="${PASSTHROUGH_PCI_DEVICES:-01:00.0}"
    if [ -n "${pci_list}" ] && mountpoint -q "${MULTIKERNEL_SYSFS}"; then
        local slot n=0 dev_nodes="" full
        for slot in ${pci_list}; do
            case "${slot}" in
                0000:*) full="${slot}" ;;
                *)      full="0000:${slot}" ;;
            esac
            dev_nodes+="                pci@${n} { pci-id = \"${full}\"; };\n"
            n=$((n + 1))
        done
        local dts="/run/mk-device-add-${name}.dts" dtb="/run/mk-device-add-${name}.dtb"
        printf '%b' "/dts-v1/;\n/plugin/;\n/ {\n    fragment@0 {\n        target-path = \"/instances/${name}\";\n        __overlay__ {\n            device-add {\n${dev_nodes}            };\n        };\n    };\n};\n" > "${dts}"
        if dtc -I dts -O dtb -o "${dtb}" "${dts}" 2>/dev/null && \
           cp "${dtb}" "${MULTIKERNEL_SYSFS}/overlays/new" 2>/dev/null; then
            sleep 2
            if dmesg | tail -20 | grep -i "device.*add\|pci.*${name}\|overlay tx.*applied successfully" > /dev/null; then
                show_status "OK" "peripherals moved to child: ${pci_list}"
            else
                show_status "WARN" "device-add overlay submitted - verify: sudo dmesg | tail -8"
            fi
        else
            show_status "WARN" "device-add compile/submit failed - child boots without peripherals (dmesg names the format)"
        fi
        rm -f "${dts}" "${dtb}"

        if [ "${SPAWN_KEEP_BOUND:-true}" != "true" ]; then
            # Release the host drivers at the boot instant
            local drv
            for slot in ${pci_list}; do
                case "${slot}" in
                    0000:*) full="${slot}" ;;
                    *)      full="0000:${slot}" ;;
                esac
                drv="/sys/bus/pci/devices/${full}/driver"
                if [ -L "${drv}" ]; then
                    echo "${full}" > "${drv}/unbind" 2>/dev/null || \
                        show_status "WARN" "driver release refused for ${full} (dmesg names it)"
                fi
            done
            show_status "INFO" "host drivers released - peripherals belong to the child until exit"
        else
            show_status "INFO" "SPAWN_KEEP_BOUND=true: Host drivers kept bound (core manages handoff)"
        fi

        # Watchdog for Anti-Lockout fallback. Waits for THIS script (the
        # operator, PID baked in) to exit before judging the instance: the
        # operator may legitimately spend minutes cycling control commands,
        # and a fixed-timer watchdog would destroy a boot still in progress.
        # 900s cap covers a hung operator; then reclaim regardless.
        # Written with a QUOTED heredoc ('EOF') so the file's own $vars are
        # literal; only values that must be baked in at write time are
        # substituted via shell parameter expansion in the printf calls below.
        local watchdog_script="/run/mk_watchdog_${name}.sh"
        local _mk="${MULTIKERNEL_SYSFS}"
        local _blog="${BOOT_LOG}"
        local _name="${name}"
        local _pci="${pci_list}"
        local _ws="${watchdog_script}"
        local _op_pid=$$
        {
            printf '#!/usr/bin/env bash\n'
            printf 'op_pid=%s\n' "${_op_pid}"
            printf 'waited=0\n'
            printf 'while kill -0 "${op_pid}" 2>/dev/null && [ "${waited}" -lt 900 ]; do\n'
            printf '    sleep 5\n'
            printf '    waited=$(( waited + 5 ))\n'
            printf 'done\n'
            printf 'sleep 10\n'
            printf 'status=$(cat "%s/instances/%s/status" 2>/dev/null || echo "absent")\n' "${_mk}" "${_name}"
            printf 'if [ "${status}" != "running" ]; then\n'
            printf '    echo -e "\\n[WATCHDOG] Operator exited, instance not running (status=${status}). Forcing reclaim..." >> "%s"\n' "${_blog}"
            printf '    echo "force-shutdown" > "%s/instances/%s/control" 2>/dev/null || true\n' "${_mk}" "${_name}"
            printf '    dts_file=$(mktemp /tmp/mk-remove-XXXXXX.dts)\n'
            printf '    dtb_file=$(mktemp /tmp/mk-remove-XXXXXX.dtb)\n'
            printf '    cat > "${dts_file}" << '"'"'RMEOF'"'"'\n'
            printf '/dts-v1/;\n/plugin/;\n/ {\n    fragment@0 {\n        target-path = "/instances";\n        __overlay__ {\n            instance-remove {\n'
            printf '                instance-name = "%s";\n' "${_name}"
            printf '            };\n        };\n    };\n};\nRMEOF\n'
            printf '    dtc -I dts -O dtb -o "${dtb_file}" "${dts_file}" 2>/dev/null && \\\n'
            printf '        cp "${dtb_file}" "%s/overlays/new" 2>/dev/null || true\n' "${_mk}"
            printf '    rm -f "${dts_file}" "${dtb_file}"\n'
            printf '    for slot in %s; do\n' "${_pci}"
            printf '        full="${slot}"\n'
            printf '        case "${slot}" in 0000:*) ;; *) full="0000:${slot}" ;; esac\n'
            printf '        drv="/sys/bus/pci/devices/${full}/driver"\n'
            printf '        [ -L "${drv}" ] && echo "${full}" > "${drv}/bind" 2>/dev/null || true\n'
            printf '    done\n'
            printf 'fi\n'
            printf 'rm -f "%s"\n' "${_ws}"
        } > "${watchdog_script}"
        chmod +x "${watchdog_script}"
        nohup "${watchdog_script}" > /dev/null 2>&1 &
    fi

    start_console_capture "${name}"

    # Control writes are ASYNCHRONOUS: the kernel runs the entire child
    # spawn inside the write syscall - a blocking echo would stall this
    # script for the whole boot while USB is dark. Background the write,
    # poll the status with a real timeout, report the verdict.
    local cmd attempted="" worked=""
    if [ "${interface}" = "control" ]; then
        for cmd in boot spawn start launch run; do
            show_status "INFO" "control write (backgrounded): '${cmd}'"
            attempted="${attempted}${cmd} "
            ( echo "${cmd}" > "${dir}/control" 2>/dev/null ) &
            local w=0
            while [ "${w}" -lt 60 ]; do
                sleep 1
                w=$((w + 1))
                if [ "$(instance_status "${name}")" = "running" ]; then
                    worked="${cmd}"
                    break
                fi
            done
            [ -n "${worked}" ] && break
            show_status "INFO" "'${cmd}' no running status in 60s"
        done
    elif [ "${interface}" != "none" ]; then
        show_status "INFO" "single-write interface: ${interface} (backgrounded)"
        attempted="${interface}-write-1"
        ( echo "1" > "${dir}/${interface}" 2>/dev/null ) &
        local w=0
        while [ "${w}" -lt 60 ]; do
            sleep 1
            w=$((w + 1))
            [ "$(instance_status "${name}")" = "running" ] && { worked="write-1"; break; }
        done
    fi

    if [ -n "${worked}" ]; then
        show_status "OK" "instance ${name} is RUNNING (control '${worked}' accepted)"
        assess_child_taint "${name}"
        return 0
    fi

    # No accepted command - surface the state loudly for one decisive read
    show_status "ERROR" "boot commands tried: ${attempted:-none}- no status=running"
    show_status "INFO" "instance files: $(ls "${dir}" 2>/dev/null | tr '\n' ' ')"
    show_status "INFO" "kernel messages:"
    dmesg | tail -8 | sed 's/^/    /'
    exit 1
}

do_destroy() {
    local name
    name=$(pick_instance) || die "no instance found"
    local dir="${MULTIKERNEL_SYSFS}/instances/${name}"

    if [ -f "${dir}/control" ]; then
        # Control writes run the child teardown INSIDE the syscall (same hang
        # class as the boot write) - background them, poll for the dir to go.
        show_status "INFO" "graceful shutdown (backgrounded, up to 30s)"
        ( echo "shutdown" > "${dir}/control" 2>/dev/null || true ) &
        local w=0
        while [ -d "${dir}" ] && [ "${w}" -lt 30 ]; do
            sleep 1
            w=$((w + 1))
        done
        if [ -d "${dir}" ]; then
            show_status "INFO" "graceful timed out - force-shutdown (backgrounded)"
            ( echo "force-shutdown" > "${dir}/control" 2>/dev/null || true ) &
            local fw=0
            while [ -d "${dir}" ] && [ "${fw}" -lt 10 ]; do
                sleep 1
                fw=$((fw + 1))
            done
        fi
    fi

    if [ -d "${dir}" ]; then
        show_status "INFO" "graceful shutdown incomplete - overlay removal"
        mk_remove_instance_overlay "${name}" || true
    fi

    stop_console_capture "${name}"
    [ ! -d "${dir}" ] && show_status "OK" "instance ${name} destroyed - host survives (FSV-1 cycle ready)" \
                      || die "instance ${name} still present"
}

case "${MODE}" in
    list)    list_instances ;;
    destroy) do_destroy ;;
    boot)    do_boot ;;
esac
