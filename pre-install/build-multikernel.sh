#!/usr/bin/env bash
# build-multikernel.sh - Fetch pinned multikernel source, apply fragment, build
# Implements docs/BUILD-MULTIKERNEL.md. Pin + fragment + verify = the
# reproducibility lock: upstream drift cannot change what gets built.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
FRAGMENT="${REPO_ROOT}/config/multikernel-proj-mk-ultra.fragment"
PINNED_COMMIT="4bc24ec0b394"
KERNEL_SRC="${KERNEL_SRC:-/opt/multikernel/linux}"
UPSTREAM="https://github.com/multikernel/linux.git"

show_status() {
    case "$1" in
        OK)    echo -e "  ${GREEN}✓${NC} $2" ;;
        WARN)  echo -e "  ${YELLOW}⚠${NC} $2" ;;
        ERROR) echo -e "  ${RED}✗${NC} $2" ;;
        INFO)  echo -e "  ${BLUE}→${NC} $2" ;;
    esac
}

check_root() {
    [ "$EUID" -eq 0 ] || { echo -e "${RED}[ERROR] run as root${NC}"; exit 1; }
}

check_toolchain() {
    show_status "STEP" "Checking build toolchain..."
    local missing=""
    local tool
    for tool in gcc make bison flex git perl; do
        command -v "${tool}" &>/dev/null || missing="${missing} ${tool}"
    done
    # library checks via pkg-config presence of headers
    [ -e /usr/include/libelf.h ] || missing="${missing} libelf-dev(elfutils-libelf-devel)"
    [ -e /usr/include/openssl/ssl.h ] || missing="${missing} libssl-dev(openssl-devel)"
    if [ -n "${missing}" ]; then
        show_status "ERROR" "Missing toolchain:${missing}"
        echo "  Arch: sudo pacman -S base-devel bc bison flex libelf openssl zstd cpio perl git kmod"
        echo "  Debian/Kali: sudo apt install build-essential libncurses-dev bison flex libelf-dev libssl-dev zstd cpio kmod dwarves git"
        echo "  Fedora: sudo dnf install @development-tools bc bison flex elfutils-libelf-devel openssl-devel zstd cpio kmod dwarves git"
        exit 1
    fi
    show_status "OK" "Toolchain complete"
}

fetch_source() {
    show_status "STEP" "Fetching multikernel source at pinned commit ${PINNED_COMMIT}..."
    if [ -d "${KERNEL_SRC}/.git" ]; then
        git -C "${KERNEL_SRC}" fetch origin 2>/dev/null || show_status "WARN" "fetch failed - using existing tree"
    else
        mkdir -p "$(dirname "${KERNEL_SRC}")"
        git clone --filter=blob:none "${UPSTREAM}" "${KERNEL_SRC}"
    fi
    git -C "${KERNEL_SRC}" checkout "${PINNED_COMMIT}"
    show_status "OK" "Source pinned: $(git -C "${KERNEL_SRC}" rev-parse --short HEAD)"
}

apply_fragment() {
    show_status "STEP" "Applying config fragment..."
    cd "${KERNEL_SRC}"

# Apply repo fork patches before building (idempotent: grep-guarded)
for pf in "${SCRIPT_DIR}/../patches/"*.patch; do
    [ -f "${pf}" ] || continue
    if grep -q "MK_CTRL_PGTABLE_PAGES" "${pf}" && \
       grep -q "#define MK_CTRL_PGTABLE_PAGES	64" "${KERNEL_SRC}/arch/x86/include/asm/multikernel.h"; then
        echo "  Applying fork patch: $(basename "${pf}")"
        if patch -d "${KERNEL_SRC}" -p1 --forward < "${pf}" >/dev/null 2>&1; then
            echo "  Applied: $(basename "${pf}")"
        else
            echo "  WARN: $(basename "${pf}") did not apply (already applied or source drift) - continuing"
        fi
    fi
done
    if [ ! -f .config ]; then
        # Base: vanilla defconfig. Distro-seeded configs (BASE_CONFIG=running
        # etc.) were evaluated and REMOVED: distro-patched symbols silently
        # drop on vanilla source, producing unpredictable builds. The
        # fragment + optional MENUCONFIG=1 is the complete, honest path.
        make defconfig
    fi
    scripts/kconfig/merge_config.sh -m .config "${FRAGMENT}"
    make olddefconfig
    show_status "OK" "Fragment merged"
    
    if [ "${MENUCONFIG:-0}" = "1" ]; then
        show_status "INFO" "Launching menuconfig - review/toggle anything, SAVE, then the build continues"
        make menuconfig
    fi
}

verify_flags() {
    show_status "STEP" "Verifying required kernel flags..."
    local missing=""
    local opt
    for opt in CONFIG_MULTIKERNEL=y CONFIG_OF=y CONFIG_OF_OVERLAY=y CONFIG_KEXEC=y CONFIG_INTEL_IOMMU=y CONFIG_IKCONFIG=y CONFIG_IKCONFIG_PROC=y; do
        grep -q "^${opt}$" .config || missing="${missing} ${opt%%=*}"
    done
    grep -qE "^CONFIG_MULTIKERNEL_VSOCKETS=(y|m)$" .config || missing="${missing} CONFIG_MULTIKERNEL_VSOCKETS"
    if [ -n "${missing}" ]; then
        show_status "ERROR" "Required flags missing:${missing} - ABORT (upstream may have changed; adjust fragment)"
        exit 1
    fi
    show_status "OK" "All required flags present"
    
    # Trust chain: when a signing key exists, wire it into the kernel's
    # built-in trusted keyring (non-SB path; SB hosts use enroll-mok.sh)
    local key_pem="/etc/secureboot/keys/signing_key.pem"
    if [ -f "${key_pem}" ]; then
        if grep -q "^CONFIG_SYSTEM_TRUSTED_KEYS=" .config; then
            local current_key
            current_key=$(grep "^CONFIG_SYSTEM_TRUSTED_KEYS=" .config | cut -d= -f2- | tr -d '"')
            if [ "${current_key}" != "${key_pem}" ]; then
                sed -i "s|^CONFIG_SYSTEM_TRUSTED_KEYS=.*|CONFIG_SYSTEM_TRUSTED_KEYS=\"${key_pem}\"|" .config
                make olddefconfig
                show_status "OK" "Trusted key updated to current signing key"
            else
                show_status "OK" "Trusted key already current"
            fi
        else
            echo "CONFIG_SYSTEM_TRUSTED_KEYS=\"${key_pem}\"" >> .config
            make olddefconfig
            show_status "OK" "Signing key wired into built-in trusted keyring (CONFIG_SYSTEM_TRUSTED_KEYS)"
        fi
    fi
}

build_and_install() {
    show_status "STEP" "Building (this takes a while)..."
    # RAM-aware job cap: ~1GB per parallel job, 2GB headroom. Full -j$(nproc)
    # on a low-RAM laptop swap-thrashes for hours and looks like a hang.
    local jobs
    jobs=$(nproc)
    local mem_gb
    mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    local max_by_mem=$(( mem_gb > 4 ? mem_gb - 2 : 2 ))
    [ "${jobs}" -gt "${max_by_mem}" ] && jobs="${max_by_mem}"
    [ "${JOBS:-}" -gt 0 ] 2>/dev/null && jobs="${JOBS}"
    show_status "INFO" "Building with -j${jobs} (${mem_gb}GB RAM, ${jobs} parallel jobs; override with JOBS=N)"
    make -j"${jobs}"
    show_status "OK" "Kernel built"
    make modules_install
    make install
    show_status "OK" "Kernel + modules installed"
}

verify_install() {
    local installed_kernel
    installed_kernel=$(ls /lib/modules | grep mk | tail -1)
    show_status "STEP" "Verifying installation..."
    [ -n "${installed_kernel}" ] || { show_status "ERROR" "No mk kernel in /lib/modules"; exit 1; }
    show_status "OK" "Installed: ${installed_kernel}"
    echo
    show_status "WARN" "Remaining manual steps (see docs/BUILD-MULTIKERNEL.md):"
    echo "  1. Initramfs: sudo mkinitcpio --kernel ${installed_kernel} -g /boot/initramfs-${installed_kernel}.img"
    echo "  2. BLS boot entry with options: intel_iommu=on iommu=pt movablecore=116G nouveau.config=NvGpuRm=1   (reference 128GB build - size YOUR zone: child ceiling + ~36G scan slack, see docs/DEPLOYMENT-GUIDE.md section 7)"
    echo "  3. Reboot into the multikernel kernel"
}

main() {
    check_root
    check_toolchain
    fetch_source
    apply_fragment
    verify_flags
    build_and_install
    verify_install
}

main "$@"
