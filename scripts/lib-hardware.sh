#!/usr/bin/env bash
# lib-hardware.sh - Shared hardware-assignment helpers
# SUSPICIOUS Framework: sourced by spawn/auto-destroy/recovery scripts so
# CPU-mask, memory and device handling has exactly one implementation.

# Persisted baseline CPU list: physical APIC IDs (space-separated hex) the
# baseline donated to the pool. dmesg rotates on a long-running host, and
# once the CPUs are parked /proc/cpuinfo no longer lists them - this file is
# the durable fallback for cpu_phys_ids_from_mask. Written on every
# successful baseline apply.
BASELINE_CPUS_FILE="${BASELINE_CPUS_FILE:-/var/lib/proj-mk-ultra/watch/baseline-cpus.txt}"

persist_baseline_cpus() {
    local ids="$1"
    [ -n "${ids}" ] || return 0
    mkdir -p "$(dirname "${BASELINE_CPUS_FILE}")" 2>/dev/null || return 0
    echo "${ids}" > "${BASELINE_CPUS_FILE}" 2>/dev/null || true
}

# Convert 16G / 512M / 1024K to bytes (integer)
size_to_bytes() {
    local size="$1"
    case "${size}" in
        *K) echo $(( ${size%K} * 1024 )) ;;
        *M) echo $(( ${size%M} * 1048576 )) ;;
        *G) echo $(( ${size%G} * 1073741824 )) ;;
        *)  echo "${size}" ;;
    esac
}

# Convert a size like 512M / 10G / 10752MiB to MiB (integer)
size_to_mib() {
    local size="$1"
    case "${size}" in
        *MiB) echo "${size%MiB}" ;;
        *M)   echo "${size%M}" ;;
        *G)   echo $(( ${size%G} * 1024 )) ;;
        *)    echo "${size}" ;;
    esac
}

# Count set bits in a hex CPU mask, optionally capped at the real CPU count
cpu_count_from_mask() {
    local mask="$1"
    local cap="${2:-}"
    local value=$(( ${mask} ))
    local count=0
    while [ "${value}" -gt 0 ]; do
        count=$(( count + value % 2 ))
        value=$(( value / 2 ))
    done
    if [ -n "${cap}" ] && [ "${count}" -gt "${cap}" ]; then
        count="${cap}"
    fi
    echo "${count}"
}

# Format a size as a hex literal suitable for device-tree cells
dts_memory_hex() {
    printf '0x%X' "$(size_to_bytes "$1")"
}

# Sum present pages across every ZONE_MOVABLE on the machine (bytes).
# The child's pool memory is carved from ZONE_MOVABLE by the multikernel
# baseline (movablecore=<child>G puts exactly that much there at boot).
movable_zone_bytes() {
    local total_pages=0 zone found=0
    while IFS= read -r line; do
        case "${line}" in
            *zone*ovable*) found=1 ;;
            "        present  "*)
                if [ "${found}" = "1" ]; then
                    total_pages=$(( total_pages + ${line##*[[:space:]]} ))
                    found=0
                fi
                ;;
        esac
    done < /proc/zoneinfo
    echo $(( total_pages * 4096 ))
}

# Translate a logical CPU mask into the physical APIC IDs the multikernel
# DTB format requires (kernel validates via arch_cpu_from_physical_id).
# Single awk pass over /proc/cpuinfo - no shell-array state, deterministic.
cpu_phys_ids_from_mask() {
    # cap is intentionally UNUSED post-baseline: once CPUs are parked in the
    # pool, nproc reflects the host remainder (4), not the child set — the
    # full mask is always the child's requested set.
    local mask="$1"
    local value count=0 i
    value=$(( ${mask} ))
    local wanted=""
    i=0
    while [ "${value}" -gt 0 ]; do
        if [ $(( value % 2 )) -eq 1 ]; then
            wanted+="${i} "
            count=$(( count + 1 ))
        fi
        value=$(( value / 2 ))
        i=$(( i + 1 ))
    done
    [ -n "${wanted}" ] || return 1

    local pool_ids
    pool_ids=$(dmesg 2>/dev/null | grep "Baseline CPU pool:" | tail -1 | sed 's/.*requested: //' | tr ',' ' ')
    if [ -z "${pool_ids}" ] && [ -f "${BASELINE_CPUS_FILE}" ]; then
        pool_ids=$(tr ',' ' ' < "${BASELINE_CPUS_FILE}")
    fi
    awk -v wanted="${wanted% }" -v pool_ids="${pool_ids}" '
        /^processor[ \t]*:/ { s=$0; gsub(/[ \t]/,"",s); cur=substr(s,11) }
        /^apicid[ \t]*:/    { s=$0; gsub(/[ \t]/,"",s); apic[cur]=substr(s,8) }
        BEGIN { split(pool_ids, pids, " "); pn = length(pids) }
        END {
            n = split(wanted, w, " ")
            # parked-CPUs fallback: after the baseline parks CPUs, /proc/cpuinfo
            # no longer lists them - but the kernel logged the pool physical IDs
            # at baseline time, in the same ascending-mask order. Positional map.
            missing = 0
            for (j = 1; j <= n; j++) if (!(w[j] in apic)) missing++
            out = ""
            if (missing == n && pn >= n) {
                for (j = 1; j <= n; j++) out = out sprintf("0x%02X ", pids[j])
            } else {
                for (j = 1; j <= n; j++) {
                    id = apic[w[j]]
                    if (id == "") {
                        printf "ERR:no-apicid-for-cpu%s\n", w[j] > "/dev/stderr"
                        exit 1
                    }
                    out = out sprintf("0x%02X ", id)
                }
            }
            sub(/ $/, "", out)
            print out
        }' /proc/cpuinfo
}

# Assess the host kernel taint per the documented policy (single
# implementation - FSV-5, the resident watcher, and the response layer all
# consume this):
#   clean     - taint == 0
#   violation - bits 12|13 (out-of-tree/unsigned module on the HOST)
#   exception - bit 18 only (the fork's own TAINT_TEST marker,
#               kernel/module/main.c:2549 - documented, no response)
#   unknown   - any other combination (review; NEVER auto-respond)
# Prints: "<status> <bits>"
assess_host_taint() {
    local taint
    taint=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo "x")
    if [ "${taint}" = "0" ]; then echo "clean 0"; return 0; fi
    if ! [[ "${taint}" =~ ^[0-9]+$ ]]; then echo "unknown x"; return 0; fi
    local bits="" n bit
    n=${taint}; bit=0
    while [ ${n} -gt 0 ]; do
        [ $(( n % 2 )) -eq 1 ] && bits+="${bit} "
        n=$(( n / 2 )); bit=$(( bit + 1 ))
    done
    local violation=0 exception=1 b
    for b in ${bits}; do
        case ${b} in
            12|13) violation=1 ;;
            18)    : ;;
            *)     exception=0 ;;
        esac
    done
    if [ ${violation} = 1 ]; then echo "violation ${bits}"; return 0; fi
    if [ ${exception} = 1 ]; then echo "exception ${bits}"; return 0; fi
    echo "unknown ${bits}"
}

# Is the multikernel pool populated with memory? (baseline already applied)
pool_populated() {
    [ "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: added')" -gt "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: removed')" ]
}

# Ensure the multikernel pool exists: apply the baseline when empty. The
# chunk must fit ZONE_MOVABLE with slack to dodge pinned pages, so normal
# operation applies it at boot via mk-baseline.service; this is the
# idempotent on-demand fallback.
mk_ensure_baseline() {
    [ "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: added')" -gt "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: removed')" ] && return 0
    local phys_ids memory_hex
    phys_ids=$(cpu_phys_ids_from_mask "${CHILD_CPU_MASK}") || return 1
    memory_hex=$(dts_memory_hex "${CHILD_MEMORY_SIZE}")
    local dts="/run/mk-host-baseline.dts" dtb="/run/mk-host-baseline.dtb"
    cat > "${dts}" << EOFTREE
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
    dtc -I dts -O dtb -o "${dtb}" "${dts}" 2>/dev/null || return 1
    local write_rc_file="/run/mk-baseline-write-rc-lib"
    ( cp "${dtb}" "${MULTIKERNEL_SYSFS}/device_tree" 2>/dev/null; echo $? > "${write_rc_file}" ) &
    local waited=0
    while [ "${waited}" -lt 120 ]; do
        if [ -f "${write_rc_file}" ]; then
            local rc
            rc=$(cat "${write_rc_file}" 2>/dev/null || echo "1")
            rm -f "${write_rc_file}"
            [ "${rc}" = "0" ] || return 1
            break
        fi
        if [ "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: added')" -gt "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: removed')" ]; then
            break
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    rm -f "${dts}" "${dtb}"
    if [ "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: added')" -gt "$(dmesg 2>/dev/null | grep -c 'Multikernel pool: removed')" ]; then
        persist_baseline_cpus "${phys_ids}"
        return 0
    fi
    return 1
}

# Create a multikernel instance via the overlay API (instance-create draws
# memory and CPUs from the pool). Returns 0 when the instance directory
# exists. NEVER sysfs mkdir - the kernel owns that tree.
mk_create_instance_overlay() {
    local name="$1"
    [ -d "${MULTIKERNEL_SYSFS}/instances/${name}" ] && return 0
    mk_ensure_baseline || return 1
    local phys_ids
    phys_ids=$(cpu_phys_ids_from_mask "${CHILD_CPU_MASK}") || return 1

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
    else
        memory_hex=$(dts_memory_hex "${CHILD_MEMORY_SIZE}")
    fi

    local kernel_path initrd_path
    kernel_path=$(find_child_kernel) || kernel_path=""
    if [ -n "${kernel_path}" ]; then
        initrd_path=$(find_child_initrd "${kernel_path}") || initrd_path=""
    fi

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

    local dts="/run/mk-instance-${name}.dts" dtb="/run/mk-instance-${name}.dtb"
    cat > "${dts}" << EOFTREE
/dts-v1/;
/plugin/;
/ {
    fragment@0 {
        target-path = "/instances";
        __overlay__ {
            instance-create {
                instance-name = "${name}";
                ${extra_nodes}resources {
                    memory-bytes = /bits/ 64 <${memory_hex}>;
                    cpus = /bits/ 64 <${phys_ids}>;
                };
            };
        };
    };
};
EOFTREE
    dtc -I dts -O dtb -o "${dtb}" "${dts}" 2>/dev/null || return 1
    cp "${dtb}" "${MULTIKERNEL_SYSFS}/overlays/new" 2>/dev/null || return 1
    rm -f "${dts}" "${dtb}"
    local waited=0
    while [ ! -d "${MULTIKERNEL_SYSFS}/instances/${name}" ] && [ "${waited}" -lt 10 ]; do
        sleep 1
        waited=$(( waited + 1 ))
    done
    [ -d "${MULTIKERNEL_SYSFS}/instances/${name}" ]
}

# Destroy an instance via the overlay API (instance-remove) - the same
# transaction system that creates it. Send a control shutdown first for
# running instances; returns 0 when the directory is gone.
mk_remove_instance_overlay() {
    local name="$1"
    [ ! -d "${MULTIKERNEL_SYSFS}/instances/${name}" ] && return 0
    local dts="/run/mk-remove-${name}.dts" dtb="/run/mk-remove-${name}.dtb"
    cat > "${dts}" << EOFTREE
/dts-v1/;
/plugin/;
/ {
    fragment@0 {
        target-path = "/instances";
        __overlay__ {
            instance-remove {
                instance-name = "${name}";
            };
        };
    };
};
EOFTREE
    dtc -I dts -O dtb -o "${dtb}" "${dts}" 2>/dev/null || return 1
    cp "${dtb}" "${MULTIKERNEL_SYSFS}/overlays/new" 2>/dev/null || return 1
    rm -f "${dts}" "${dtb}"
    local waited=0
    while [ -d "${MULTIKERNEL_SYSFS}/instances/${name}" ] && [ "${waited}" -lt 10 ]; do
        sleep 1
        waited=$(( waited + 1 ))
    done
    [ ! -d "${MULTIKERNEL_SYSFS}/instances/${name}" ]
}

# Resolve a child device path tolerantly: if the configured /dev/sdXY path
# does not exist (USB enumeration flips letters across boots - observed twice
# on the reference hardware), try the letter-swapped sibling (sda<->sdb).
# Resolves the ACTUAL existing path or returns the original for the caller's
# loud failure. by-id paths are returned untouched (already stable).
resolve_child_device() {
    local dev="$1"
    [ -e "${dev}" ] && { echo "${dev}"; return 0; }
    case "${dev}" in
        /dev/sda[0-9]) local alt="${dev/sda/sdb}" ;;
        /dev/sdb[0-9]) local alt="${dev/sdb/sda}" ;;
        *) echo "${dev}"; return 0 ;;
    esac
    if [ -e "${alt}" ]; then
        echo "${alt}"
        return 0
    fi
    echo "${dev}"
    return 1
}

# Locate the multikernel kernel image: config override, then newest
# /boot multikernel build, then the packaged path
find_child_kernel() {
    if [ -n "${CHILD_KERNEL_PATH:-}" ] && [ -f "${CHILD_KERNEL_PATH}" ]; then
        echo "${CHILD_KERNEL_PATH}"
        return 0
    fi
    local discovered
    # Arch's `make install` names kernels vmlinuz-<version> (version contains
    # mk2); a plain `linux` filename never exists there.
    discovered=$(find /boot -maxdepth 1 -name "vmlinuz-*mk2*" -type f 2>/dev/null | sort | tail -1 || true)
    if [ -n "${discovered}" ]; then
        echo "${discovered}"
        return 0
    fi
    if [ -f /boot/vmlinuz-linux-multikernel ]; then
        echo "/boot/vmlinuz-linux-multikernel"
        return 0
    fi
    return 1
}

# Locate the initramfs sibling to the kernel image
find_child_initrd() {
    local kernel_path="$1"
    local kernel_dir
    kernel_dir=$(dirname "${kernel_path}")
    if [ -n "${CHILD_INITRD_PATH:-}" ] && [ -f "${CHILD_INITRD_PATH}" ]; then
        echo "${CHILD_INITRD_PATH}"
        return 0
    fi
    # Arch convention: initramfs-<version>.img siblings vmlinuz-<version>
    local ver_img="${kernel_dir}/initramfs-$(basename "${kernel_path}" | sed 's/^vmlinuz-//').img"
    if [ -f "${ver_img}" ]; then
        echo "${ver_img}"
        return 0
    fi
    if [ -f "${kernel_dir}/initrd" ]; then
        echo "${kernel_dir}/initrd"
        return 0
    fi
    if [ -f /boot/initramfs-linux-multikernel.img ]; then
        echo "/boot/initramfs-linux-multikernel.img"
        return 0
    fi
    return 1
}

# Loud, specific, actionable missing-parameter validation. Suggested defaults
# come directly from the .example template. Call at script entry with the
# keys the script cannot proceed without.
validate_required_config() {
    local conf
    conf="${CONFIG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../etc/proj-mk-ultra.conf}"
    local example="${conf}.example"
    [ -f "${example}" ] || example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../etc/proj-mk-ultra.conf.example"
    local missing=0 key val sugg
    for key in "$@"; do
        val=$(grep "^${key}=" "${conf}" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d ' ')
        if [ -z "${val}" ]; then
            sugg=$(grep "^${key}=" "${example}" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"')
            echo -e "  \033[0;31m✗ MISSING PARAMETER: ${key}\033[0m"
            echo -e "    You forgot to set the ${key} parameter. Please edit that line within your"
            echo -e "    ${conf} configuration file."
            if [ -n "${sugg}" ]; then
                echo -e "    Note - Suggested default: ${sugg}"
            else
                echo -e "    Note - Template leaves this unset (auto-populated during install). Run useful-scripts/generate-config.sh or the wizard to populate it."
            fi
            missing=$((missing + 1))
        fi
    done
    if [ "${missing}" -gt 0 ]; then
        echo -e "  \033[0;31m${missing} required parameter(s) missing - fix the lines above, then re-run.\033[0m"
        return 1
    fi
    return 0
}
