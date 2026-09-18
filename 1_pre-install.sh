#!/usr/bin/env bash
# pre-install.sh - Complete pre-setup preparation for PROJ-MK-ULTRA
# Automates EVERYTHING scriptable before setup.sh can run on a fresh machine:
#   1. Build dependencies (per-distro)
#   2. multikernel/linux clone -> /opt/multikernel/linux at the pinned commit
#   3. Config fragment merge + required-flag verification
#   4. Kernel build + install
#   5. Boot entry creation (systemd-boot BLS or GRUB 40_custom; best-effort,
#      bootloader edits stay reviewable)
#   6. Config bootstrap (generate-config from real hardware, template fallback)
#   7. Prints the EXACT human checklist for the remaining physical acts
#
# Usage: sudo ./pre-install.sh [--skip-build]
#   --skip-build : source already built - only do boot entry + checklist

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 1_pre-install.sh lives at the repo root
REPO_ROOT="${SCRIPT_DIR}"

# Sanity: refuse incomplete/stale copies (Trash, partial transfers) LOUDLY,
# naming the exact invoked path so a stale copy can never masquerade
if [ ! -f "${REPO_ROOT}/config/multikernel-proj-mk-ultra.fragment" ] || \
   [ ! -f "${REPO_ROOT}/etc/proj-mk-ultra.conf.example" ]; then
    echo -e "${RED}${BOLD}✗ INCOMPLETE REPO COPY at: ${REPO_ROOT}${NC}"
    echo -e "${RED}  Invoked via: ${BASH_SOURCE[0]}${NC}"
    echo -e "${YELLOW}  Missing config fragment/example - this is a stale or partial copy"
    echo -e "  (common cause: running the script from ~/.local/share/Trash or a"
    echo -e "  partially-transferred tree). Run the script from a COMPLETE repo clone.${NC}"
    exit 1
fi
KERNEL_SRC="${KERNEL_SRC:-/opt/multikernel/linux}"
PINNED_COMMIT="4bc24ec0b394"
UPSTREAM="https://github.com/multikernel/linux.git"
FRAGMENT="${REPO_ROOT}/config/multikernel-proj-mk-ultra.fragment"
CONF="${REPO_ROOT}/etc/proj-mk-ultra.conf"
EXAMPLE="${REPO_ROOT}/etc/proj-mk-ultra.conf.example"

# Memory layout globals: computed once (main), consumed by the boot-entry
# builder AND the human checklist - the checklist used to reference
# create_boot_entry locals and died on set -u ("unbound variable").
PHYS_GB="" ZONE_GB="" CHILD_GB="" MOVABLE_LINE=""

compute_memory_layout() {
    local total_gb
    total_gb=$(free -g | awk '/^Mem:/{print $2}')
    PHYS_GB=$(( (total_gb + 7) / 8 * 8 ))
    ZONE_GB=$(( PHYS_GB - 12 ))
    CHILD_GB=$(( ZONE_GB - 36 ))
    MOVABLE_LINE="movablecore=${ZONE_GB}G"
}

say()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()   { echo -e "  ${RED}✗${NC} $*"; }
step()  { echo -e "\n${BOLD}═══ $* ═══${NC}"; }

check_root() {
    [ "$EUID" -eq 0 ] || { err "run as root: sudo ./pre-install.sh"; exit 1; }
}

detect_pkg() {
    for pm in pacman apt dnf; do command -v "$pm" &>/dev/null && { echo "$pm"; return; }; done
    echo "unknown"
}

install_deps() {
    step "1. Build dependencies"
    local pkg; pkg=$(detect_pkg)
    case "$pkg" in
        pacman)
            pacman -Sy --needed --noconfirm base-devel bc bison flex libelf openssl zstd cpio perl git kmod dtc parted dosfstools btrfs-progs rsync arch-install-scripts pciutils openssh dwarves ncurses debootstrap
            say "Arch deps installed"
            ;;
        apt)
            apt update -qq
            DEBIAN_FRONTEND=noninteractive apt install -y build-essential libncurses-dev bison flex libelf-dev libssl-dev zstd cpio kmod dwarves git device-tree-compiler parted dosfstools btrfs-progs rsync debootstrap
            say "Debian/Kali deps installed"
            ;;
        dnf)
            dnf install -y @development-tools bc bison flex elfutils-libelf-devel openssl-devel zstd cpio kmod dwarves git dtc parted dosfstools btrfs-progs rsync
            say "Fedora deps installed"
            ;;
        *)
            err "Unknown package manager. Install manually:"
            echo "  Debian/Kali: build-essential libncurses-dev bison flex libelf-dev libssl-dev zstd cpio kmod dwarves git device-tree-compiler parted dosfstools btrfs-progs rsync"
            echo "  Arch: base-devel bc bison flex libelf openssl zstd cpio perl git kmod dtc parted dosfstools btrfs-progs rsync arch-install-scripts"
            echo "  Fedora: @development-tools bc bison flex elfutils-libelf-devel openssl-devel zstd cpio kmod dwarves git dtc parted dosfstools btrfs-progs rsync"
            exit 1
            ;;
    esac
}

fetch_kernel() {
    step "2. multikernel/linux -> ${KERNEL_SRC} (pinned: ${PINNED_COMMIT})"
    if [ -d "${KERNEL_SRC}/.git" ]; then
        say "Source tree exists - fetching pinned commit"
        git -C "${KERNEL_SRC}" fetch origin 2>/dev/null || warn "fetch failed - using existing tree"
    else
        mkdir -p "$(dirname "${KERNEL_SRC}")"
        say "Cloning (blobless for speed, full history for the pin)..."
        git clone --filter=blob:none "${UPSTREAM}" "${KERNEL_SRC}"
    fi
    if ! git -C "${KERNEL_SRC}" checkout "${PINNED_COMMIT}" 2>/dev/null; then
        if git -C "${KERNEL_SRC}" fetch origin 2>/dev/null; then
            git -C "${KERNEL_SRC}" checkout "${PINNED_COMMIT}" 2>/dev/null || true
        fi
    fi
    git -C "${KERNEL_SRC}" checkout "${PINNED_COMMIT}" >/dev/null 2>&1 || {
        err "Pinned commit ${PINNED_COMMIT} not reachable - upstream may have diverged."
        echo "  Fix (as root - /opt is root-owned):"
        echo "    sudo git -C ${KERNEL_SRC} fetch origin"
        echo "    sudo git -C ${KERNEL_SRC} checkout ${PINNED_COMMIT}"
        echo "  Or simply re-run: sudo ./pre-install.sh (fetches and checks out as root)"
        exit 1
    }
    say "Source pinned: $(git -C "${KERNEL_SRC}" rev-parse --short HEAD)"
}

build_kernel() {
    step "3. Build + install (fragment merged, flags verified)"
    if [ ! -f "${FRAGMENT}" ]; then
        err "Config fragment missing: ${FRAGMENT}"
        exit 1
    fi
    export KERNEL_SRC
    if ! bash "${REPO_ROOT}/pre-install/build-multikernel.sh"; then
        err "Kernel build failed - review the output above, fix, re-run: sudo ./pre-install.sh --skip-build"
        exit 1
    fi
}

find_kernel_version() {
    if [ -d "${KERNEL_SRC}" ]; then
        ( cd "${KERNEL_SRC}" && make kernelrelease 2>/dev/null ) || true
    fi
}

create_boot_entry() {
    step "4. Boot entry (best-effort - the options line is ALWAYS human-reviewable)"
    local ver
    ver=$(find_kernel_version)
    [ -n "${ver}" ] || { warn "Kernel version not determined - create the entry manually (see checklist)"; return; }
    
    # Initramfs: regenerate with the repo's mkinitcpio config when available
    if command -v mkinitcpio &>/dev/null; then
        say "Generating initramfs for ${ver}"
        mkinitcpio --kernel "${ver}" -g "/boot/initramfs-${ver}.img" 2>/dev/null \
            || warn "mkinitcpio failed - generate manually (see checklist)"
    fi
    
    # Locate the installed kernel image
    local kernel_img=""
    for candidate in "/boot/vmlinuz-${ver}" "/boot/vmlinuz-linux-multikernel"; do
        [ -f "${candidate}" ] && { kernel_img="${candidate}"; break; }
    done
    [ -n "${kernel_img}" ] || { warn "Kernel image not found in /boot - create the entry manually (see checklist)"; return; }
    
    # movablecore line: host keeps a ~12G non-movable base; the zone holds
    # the child pool + 36G contig-allocation scan slack (reference: 128GB
    # machine -> movablecore=116G, child=80G).
    if [ -z "${MOVABLE_LINE}" ]; then compute_memory_layout; fi

    if [ -d /boot/loader/entries ] && command -v bootctl &>/dev/null; then
        local entry="/boot/loader/entries/multikernel-${ver}.conf"
        [ -f "${entry}" ] && { warn "Entry exists: ${entry} - NOT overwritten (review it manually)"; return; }
        cat > "${entry}" << EOF
title   PROJ-MK-ULTRA Multikernel (${ver})
linux   ${kernel_img#/boot}
initrd  /initramfs-${ver}.img
options root=$(findmnt -n -o SOURCE / 2>/dev/null || echo "REPLACE-ME") rw intel_iommu=on iommu=pt ${MOVABLE_LINE} $( [ -e /sys/module/nouveau ] || [ -d /sys/bus/pci/drivers/nouveau ] && echo nouveau.config=NvGpuRm=1 )
EOF
        say "BLS entry created: ${entry}"
        warn "REVIEW the options line: root= must match YOUR root device; ${MOVABLE_LINE} = child ${CHILD_GB}G + 36G contig slack on ${PHYS_GB}GB physical RAM"
    elif command -v grub-mkconfig &>/dev/null; then
        add_grub_entry "${ver}" "${kernel_img}"
    else
        warn "No systemd-boot or GRUB detected - add a boot entry manually (see checklist)"
    fi
}

# Best-effort GRUB entry: append to /etc/grub.d/40_custom (never overwrite),
# locate the boot filesystem by UUID, and regenerate grub.cfg. Paths are
# relative to the boot fs - they differ when /boot is a separate partition.
add_grub_entry() {
    local ver="$1" kernel_img="$2"
    local custom="/etc/grub.d/40_custom"
    if grep -q "multikernel-${ver}" "${custom}" 2>/dev/null; then
        warn "GRUB entry for ${ver} already in ${custom} - NOT duplicated (review it manually)"
        return
    fi
    local boot_src boot_uuid kpath ipath
    boot_src=$(findmnt -n -o SOURCE /boot 2>/dev/null || findmnt -n -o SOURCE /)
    boot_uuid=$(blkid -s UUID -o value "${boot_src}" 2>/dev/null || true)
    if [ -z "${boot_uuid}" ]; then
        warn "Boot filesystem UUID not resolvable - add the GRUB entry manually (see checklist)"
        return
    fi
    if findmnt -n -o SOURCE /boot >/dev/null 2>&1; then
        kpath="${kernel_img#/boot}"
        ipath="/initramfs-${ver}.img"
    else
        kpath="${kernel_img}"
        ipath="/boot/initramfs-${ver}.img"
    fi
    cat >> "${custom}" << EOF

menuentry 'PROJ-MK-ULTRA Multikernel (${ver})' --class gnu-linux {
    search --no-floppy --fs-uuid --set=root ${boot_uuid}
    linux ${kpath} root=$(findmnt -n -o SOURCE / 2>/dev/null || echo "REPLACE-ME") rw intel_iommu=on iommu=pt ${MOVABLE_LINE}
    initrd ${ipath}
}
EOF
    if grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; then
        say "GRUB entry added to ${custom} + grub.cfg regenerated"
        warn "REVIEW the entry: root= must match YOUR root device; ${MOVABLE_LINE} = child ${CHILD_GB}G + 36G contig slack on ${PHYS_GB}GB physical RAM"
    else
        warn "grub-mkconfig failed - entry is in ${custom}; regenerate manually"
    fi
}

bootstrap_conf() {
    step "5. Configuration bootstrap"
    if [ -f "${CONF}" ]; then
        say "Config exists: ${CONF} (left untouched)"
        warn "Verify its values match THIS machine: useful-scripts/generate-config.sh (dry run prints hardware-detected values)"
        return 0
    fi
    if printf 'y\n' | bash "${REPO_ROOT}/useful-scripts/generate-config.sh" --write && [ -f "${CONF}" ]; then
        say "Config generated from real hardware: ${CONF}"
        warn "Review PASSTHROUGH_PCI_DEVICES and TARGET_DISK before running the wizard"
    else
        cp "${EXAMPLE}" "${CONF}"
        say "Config created from template: ${CONF}"
        warn "Template defaults - replace with hardware-detected values: useful-scripts/generate-config.sh --write"
    fi
}

human_checklist() {
    step "6. HUMAN CHECKLIST - the exact remaining physical acts"
    if [ -z "${MOVABLE_LINE}" ]; then compute_memory_layout; fi
    echo
    echo -e "${BOLD}Scripted part complete. These are YOURS to perform and verify:${NC}"
    echo
    echo "  1. REVIEW the boot entry (multikernel-*.conf in /boot/loader/entries/ or /etc/grub.d/40_custom):"
    echo "     - root= matches YOUR root device (script may have guessed wrong on LUKS/btrfs)"
    echo "     - ${MOVABLE_LINE} matches YOUR physical RAM (child = ${CHILD_GB}G, zone ${ZONE_GB}G minus ~36G contig slack)"
    echo "     - nouveau.config=NvGpuRm=1 present if you run an RTX 40-series on nouveau"
    echo "  2. REBOOT into the multikernel kernel (select it in the boot menu)"
    echo "  3. VERIFY after reboot:"
    echo "       uname -r                          # contains mk2"
    echo "       grep -A8 'zone.*Movable' /proc/zoneinfo | grep present   # movablecore acknowledged"
    echo "       lsmem | tail -3                   # zone layout == child size"
    echo "       cat /proc/sys/kernel/tainted      # mk kernel: 262144 (bit 18 TAINT_TEST, documented); stock kernels: 0"
    echo "  4. INSERT the SD/secondary disk, confirm the device name: lsblk"
    echo "  5. Review/edit etc/proj-mk-ultra.conf (step 5 generated or kept it)"
    echo "  6. RUN THE WIZARD: sudo ./2_setup.sh"
    echo "  7. After install: sudo ./scripts/spawn-child-instance.sh --check  (preflight)"
    echo "  8. sudo ./scripts/first-spawn-validate.sh --pre-spawn BEFORE the first spawn"
    echo
    echo -e "${BOLD}Human gates are exactly: boot-entry review, the reboot, disk insertion,${NC}"
    echo -e "${BOLD}typed confirmations in the wizard, and the FSV report read.${NC}"
    echo
}

main() {
    show_banner() { echo -e "${BOLD}${BLUE}PROJ-MK-ULTRA PRE-INSTALL — everything scriptable, loudly${NC}"; }
    show_banner
    check_root
    compute_memory_layout
    
    if [ "${1:-}" = "--skip-build" ]; then
        create_boot_entry
        bootstrap_conf
        human_checklist
        exit 0
    fi
    
    install_deps
    fetch_kernel
    build_kernel
    create_boot_entry
    bootstrap_conf
    human_checklist
}

main "$@"
