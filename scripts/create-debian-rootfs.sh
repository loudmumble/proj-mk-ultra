#!/usr/bin/env bash
# create-debian-rootfs.sh - Create Debian rootfs for child kernel
# SUSPICIOUS Framework: Cross-Distro Support

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

TARGET_DIR="${1:-/mnt/child-root}"
SUITE="${2:-bookworm}"
MIRROR="${3:-http://deb.debian.org/debian}"

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

check_debootstrap() {
    if ! command -v debootstrap &> /dev/null; then
        show_status "ERROR" "debootstrap not found"
        show_status "INFO" "Install with: pacman -S debootstrap (or apt install debootstrap)"
        return 1
    fi
    show_status "OK" "debootstrap found"
}

create_rootfs() {
    echo -e "\n${BOLD}Creating Debian ${SUITE} rootfs...${NC}"
    
    show_status "INFO" "Target: ${TARGET_DIR}"
    show_status "INFO" "Suite: ${SUITE}"
    show_status "INFO" "Mirror: ${MIRROR}"
    
    mkdir -p "${TARGET_DIR}"
    
    debootstrap \
        --include=linux-image-amd64,linux-headers-amd64,systemd,systemd-sysv,dbus \
        --arch=amd64 \
        "${SUITE}" \
        "${TARGET_DIR}" \
        "${MIRROR}"
    
    if [ $? -eq 0 ]; then
        show_status "OK" "Debian rootfs created"
    else
        show_status "ERROR" "Failed to create Debian rootfs"
        return 1
    fi
}

configure_rootfs() {
    echo -e "\n${BOLD}Configuring rootfs...${NC}"
    
    # Configure fstab
    cat > "${TARGET_DIR}/etc/fstab" << 'EOF'
# SUSPICIOUS Framework - Child Kernel fstab
# UUIDs will be filled in by install-child-kernel.sh
EOF
    
    # Configure hostname
    echo "suspicious-child" > "${TARGET_DIR}/etc/hostname"
    
    # Configure network (disabled)
    echo "# SUSPICIOUS Framework - No network" > "${TARGET_DIR}/etc/resolv.conf"
    
    # Disable unnecessary services
    chroot "${TARGET_DIR}" systemctl disable sshd 2>/dev/null || true
    chroot "${TARGET_DIR}" systemctl disable rpcbind 2>/dev/null || true
    
    show_status "OK" "Rootfs configured"
}

install_multikernel_modules() {
    echo -e "\n${BOLD}Installing multikernel modules...${NC}"
    
    local kernel_version
    kernel_version=$(uname -r)
    
    local modules_dir="${TARGET_DIR}/lib/modules/${kernel_version}"
    
    if [ -d "/lib/modules/${kernel_version}" ]; then
        mkdir -p "${modules_dir}"
        cp -r "/lib/modules/${kernel_version}"/* "${modules_dir}/" 2>/dev/null || true
        show_status "OK" "Multikernel modules installed"
    else
        show_status "WARN" "Multikernel modules not found for ${kernel_version}"
        show_status "INFO" "Modules will need to be installed after first boot"
    fi
}

show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  DEBIAN ROOTFS CREATED${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Target: ${TARGET_DIR}"
    echo -e "  Suite: ${SUITE}"
    echo -e "  Mirror: ${MIRROR}"
    echo
}

main() {
    echo -e "${BOLD}Creating Debian Rootfs for PROJ-MK-ULTRA${NC}"
    
    check_root
    check_debootstrap
    create_rootfs
    configure_rootfs
    install_multikernel_modules
    show_summary
}

main "$@"
