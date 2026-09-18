#!/usr/bin/env bash
# create-rpm-rootfs.sh - Create RPM-based rootfs for child kernel
# SUSPICIOUS Framework: Cross-Distro Support

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

TARGET_DIR="${1:-/mnt/child-root}"
RELEASE="${2:-39}"
REPO="${3:-https://download.fedoraproject.org/pub/fedora/linux/releases}"

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

check_dnf() {
    if ! command -v dnf &> /dev/null; then
        show_status "ERROR" "dnf not found"
        show_status "INFO" "Install with: pacman -S dnf (or apt install dnf)"
        return 1
    fi
    show_status "OK" "dnf found"
}

create_rootfs() {
    echo -e "\n${BOLD}Creating Fedora ${RELEASE} rootfs...${NC}"
    
    show_status "INFO" "Target: ${TARGET_DIR}"
    show_status "INFO" "Release: ${RELEASE}"
    show_status "INFO" "Repo: ${REPO}"
    
    mkdir -p "${TARGET_DIR}"
    
    dnf \
        --installroot="${TARGET_DIR}" \
        --releasever="${RELEASE}" \
        --repo=fedora \
        --repo=updates \
        install -y \
        @core \
        kernel \
        kernel-modules \
        systemd \
        systemd-resolved \
        dbus
    
    if [ $? -eq 0 ]; then
        show_status "OK" "Fedora rootfs created"
    else
        show_status "ERROR" "Failed to create Fedora rootfs"
        return 1
    fi
}

configure_rootfs() {
    echo -e "\n${BOLD}Configuring rootfs...${NC}"
    
    cat > "${TARGET_DIR}/etc/fstab" << 'EOF'
# SUSPICIOUS Framework - Child Kernel fstab
# UUIDs will be filled in by install-child-kernel.sh
EOF
    
    echo "suspicious-child" > "${TARGET_DIR}/etc/hostname"
    echo "# SUSPICIOUS Framework - No network" > "${TARGET_DIR}/etc/resolv.conf"
    
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
    echo -e "${BOLD}  FEDORA ROOTFS CREATED${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Target: ${TARGET_DIR}"
    echo -e "  Release: ${RELEASE}"
    echo -e "  Repo: ${REPO}"
    echo
}

main() {
    echo -e "${BOLD}Creating Fedora Rootfs for PROJ-MK-ULTRA${NC}"
    
    check_root
    check_dnf
    create_rootfs
    configure_rootfs
    install_multikernel_modules
    show_summary
}

main "$@"
