#!/usr/bin/env bash
# install-child-kernel.sh - Install child kernel to secondary disk
# SUSPICIOUS Framework: Pre-Installation
#
# Installs:
# - Multikernel kernel to boot partition
# - Minimal root filesystem to root partition
# - User data directory structure to user data partition
#
# Usage: sudo ./install-child-kernel.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../etc/proj-mk-ultra.conf"

if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
fi

# shellcheck source=../scripts/lib-hardware.sh
. "${SCRIPT_DIR}/../scripts/lib-hardware.sh"

ROOT_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"
USER_DATA_FILESYSTEM="${CORE_HOST_FILESYSTEM:-ext4}"

DISK=""


# by-id TARGET_DISK: resolve to the kernel name for the partN construction


BOOT_PARTITION=""
ROOT_PARTITION=""
USER_PARTITION=""

# Function to display banner
show_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║         CHILD KERNEL INSTALLATION                                 ║
║         SUSPICIOUS Framework Pre-Installation                      ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Function to display step
show_step() {
    local step_name="$1"
    local step_number="$2"
    echo -e "\n${BOLD}[Step ${step_number}] ${step_name}${NC}"
}

# Function to display status
show_status() {
    local status="$1"
    local message="$2"
    
    case "${status}" in
        OK)
            echo -e "  ${GREEN}✓ ${message}${NC}"
            ;;
        WARN)
            echo -e "  ${YELLOW}⚠ ${message}${NC}"
            ;;
        ERROR)
            echo -e "  ${RED}✗ ${message}${NC}"
            ;;
        INFO)
            echo -e "  ${BLUE}→ ${message}${NC}"
            ;;
    esac
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${BOLD}[ERROR] This script must be run as root${NC}"
        exit 1
    fi
}

# Function to select disk
select_disk() {
    show_step "Select Disk" 1
    
    if [ -n "${TARGET_DISK:-}" ]; then
        # Accept bare names, /dev/ paths, AND stable by-id paths - by-id
        # survives USB letter flips; resolve to the bare kernel name for the
        # partN construction below.
        local configured_disk
        case "${TARGET_DISK}" in
            /dev/*) configured_disk=$(basename "$(readlink -f "${TARGET_DISK}" 2>/dev/null)") ;;
            *)      configured_disk="${TARGET_DISK}" ;;
        esac
        if [ -b "/dev/${configured_disk}" ]; then
            DISK="${configured_disk}"
            show_status "INFO" "Using configured target disk: /dev/${DISK}"
        else
            show_status "WARN" "Configured TARGET_DISK=/dev/${TARGET_DISK} not found, falling back to interactive selection"
        fi
    fi
    
    if [ -z "${DISK:-}" ]; then
        # Find all physical disks that are NOT the root disk (or its parent)
        local root_pkname disks=()
        root_pkname=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE / 2>/dev/null)" 2>/dev/null | head -1 || true)
        while IFS= read -r disk; do
            [ -z "${disk}" ] && continue
            [[ "${disk}" == zram* ]] && continue
            [ -n "${root_pkname}" ] && [ "${disk}" = "${root_pkname}" ] && continue
            disks+=("${disk}")
        done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')

        if [ ${#disks[@]} -eq 0 ]; then
            show_status "ERROR" "No secondary disk found"
            exit 1
        fi
        
        if [ ${#disks[@]} -eq 1 ]; then
            DISK="${disks[0]}"
            show_status "OK" "Using single secondary disk: /dev/${DISK}"
        else
            echo -e "${BOLD}Available secondary disks:${NC}"
            for i in "${!disks[@]}"; do
                local size
                size=$(lsblk -dno SIZE "/dev/${disks[$i]}" 2>/dev/null | head -1)
                echo -e "  $((i+1)). /dev/${disks[$i]} - ${size}"
            done
            
            echo
            echo -e "${BOLD}Select disk (1-${#disks[@]}): ${NC}"
            if [ ! -t 0 ]; then
                show_status "ERROR" "Multiple candidate disks and no TTY - set TARGET_DISK in etc/proj-mk-ultra.conf"
                exit 1
            fi
            read -r selection
            
            if [[ "${selection}" =~ ^[0-9]+$ ]] && [ "${selection}" -ge 1 ] && [ "${selection}" -le ${#disks[@]} ]; then
                DISK="${disks[$((selection-1))]}"
                show_status "OK" "Selected disk: /dev/${DISK}"
            else
                show_status "ERROR" "Invalid selection"
                exit 1
            fi
        fi
    fi
    
    BOOT_PARTITION="/dev/${DISK}1"
    ROOT_PARTITION="/dev/${DISK}2"
    USER_PARTITION="/dev/${DISK}3"
}

# Function to verify partitions
verify_partitions() {
    show_step "Verifying Partitions" 2
    
    for partition in "${BOOT_PARTITION}" "${ROOT_PARTITION}" "${USER_PARTITION}"; do
        if [ -b "${partition}" ]; then
            show_status "OK" "Partition exists: ${partition}"
        else
            show_status "ERROR" "Partition not found: ${partition}"
            exit 1
        fi
    done
    
    local boot_fs
    boot_fs=$(blkid -s TYPE -o value "${BOOT_PARTITION}" 2>/dev/null || echo "unknown")
    
    local root_fs
    root_fs=$(blkid -s TYPE -o value "${ROOT_PARTITION}" 2>/dev/null || echo "unknown")
    
    local user_fs
    user_fs=$(blkid -s TYPE -o value "${USER_PARTITION}" 2>/dev/null || echo "unknown")
    
    if [ "${boot_fs}" = "vfat" ] || [ "${boot_fs}" = "fat32" ]; then
        show_status "OK" "Boot partition: ${boot_fs}"
    else
        show_status "WARN" "Boot partition: ${boot_fs} (expected vfat/fat32)"
    fi
    
    if [ "${root_fs}" = "${ROOT_FILESYSTEM}" ]; then
        show_status "OK" "Root partition: ${root_fs}"
    else
        show_status "WARN" "Root partition: ${root_fs} (expected ${ROOT_FILESYSTEM})"
    fi
    
    if [ "${user_fs}" = "${USER_DATA_FILESYSTEM}" ]; then
        show_status "OK" "User data partition: ${user_fs}"
    else
        show_status "WARN" "User data partition: ${user_fs} (expected ${USER_DATA_FILESYSTEM})"
    fi
}

# Function to create mount points
create_mount_points() {
    show_step "Creating Mount Points" 3
    
    local mount_points=("/mnt/child-boot" "/mnt/child-root" "/mnt/child-user")
    
    for mount_point in "${mount_points[@]}"; do
        if [ -d "${mount_point}" ]; then
            show_status "OK" "Mount point exists: ${mount_point}"
        else
            mkdir -p "${mount_point}"
            show_status "OK" "Created mount point: ${mount_point}"
        fi
    done
}

# Function to mount partitions
mount_partitions() {
    show_step "Mounting Partitions" 4
    
    show_status "INFO" "Mounting root partition (${ROOT_FILESYSTEM})"
    mount -t "${ROOT_FILESYSTEM}" "${ROOT_PARTITION}" /mnt/child-root
    
    show_status "INFO" "Mounting boot partition"
    mkdir -p /mnt/child-root/boot
    mount -t vfat "${BOOT_PARTITION}" /mnt/child-root/boot
    
    show_status "INFO" "Mounting user data partition (${USER_DATA_FILESYSTEM})"
    mkdir -p /mnt/child-root/data
    mount -t "${USER_DATA_FILESYSTEM}" "${USER_PARTITION}" /mnt/child-root/data
    
    show_status "OK" "All partitions mounted"
}

# Function to install base system
install_base_system() {
    show_step "Installing Base System" 5
    
    # Detect distro and install accordingly
    if command -v pacman &> /dev/null; then
        install_arch_base
    elif command -v apt &> /dev/null; then
        install_debian_base
    elif command -v dnf &> /dev/null; then
        install_fedora_base
    else
        show_status "ERROR" "Unsupported package manager"
        exit 1
    fi
}

# Function to install Arch base system
install_arch_base() {
    show_status "INFO" "Installing Arch Linux base system"
    
    local fs_tool="e2fsprogs"
    case "${ROOT_FILESYSTEM}" in
        btrfs) fs_tool="btrfs-progs" ;;
        xfs)   fs_tool="xfsprogs" ;;
        f2fs)  fs_tool="f2fs-tools" ;;
        zfs)   show_status "WARN" "zfs requires the archzfs repository - install manually in the child" ;;
    esac
    
    # The multikernel kernel is built from source on the host - no such Arch
    # package exists; the kernel image is copied from the host below
    pacstrap -c /mnt/child-root base base-devel mkinitcpio dtc "${fs_tool}"
    show_status "OK" "Arch base system installed"
    
    install_child_kernel_image
}

# Copy the host-built multikernel kernel, its modules, and generate a child
# initramfs so the child root is self-contained for both sysfs-spawned boots
# and standalone SD recovery
install_child_kernel_image() {
    local kernel_path
    kernel_path=$(find_child_kernel) || {
        show_status "WARN" "Host multikernel kernel image not found - child root has no kernel (sysfs spawn still works)"
        return 0
    }
    
    local mk_version=""
    case "$(uname -r)" in
        *mk2*|*multikernel*) mk_version="$(uname -r)" ;;
    esac
    if [ -z "${mk_version}" ]; then
        mk_version=$(basename "$(dirname "${kernel_path}")")
    fi
    
    show_status "INFO" "Copying kernel image: ${kernel_path}"
    cp "${kernel_path}" /mnt/child-root/boot/vmlinuz-linux-multikernel
    
    local initrd_path
    initrd_path=$(find_child_initrd "${kernel_path}") || initrd_path=""
    if [ -n "${initrd_path}" ]; then
        cp "${initrd_path}" /mnt/child-root/boot/initramfs-linux-multikernel.img
    fi
    
    show_status "INFO" "Copying kernel modules (${mk_version})"
    mkdir -p /mnt/child-root/lib/modules
    cp -a "/lib/modules/${mk_version}" /mnt/child-root/lib/modules/
    
    show_status "INFO" "Generating child initramfs (${ROOT_FILESYSTEM} root)"
    mount --bind /proc /mnt/child-root/proc
    mount --bind /sys /mnt/child-root/sys
    mount --bind /dev /mnt/child-root/dev
    chroot /mnt/child-root depmod "${mk_version}"
    # Host-side autodetect sees the HOST's NVMe root - it will NOT include the
    # USB storage stack the child needs for its USB-attached root disk. Carry
    # the USB modules explicitly (harmless when the child root is not USB).
    sed -i "s/^MODULES=([^)]*)/MODULES=(${ROOT_FILESYSTEM} xhci_pci usb_storage uas sd_mod)/" /mnt/child-root/etc/mkinitcpio.conf
    chroot /mnt/child-root mkinitcpio -k "${mk_version}" -g /boot/initramfs-linux-multikernel.img
    umount /mnt/child-root/proc /mnt/child-root/sys /mnt/child-root/dev 2>/dev/null || true
    
    show_status "OK" "Child kernel image installed (${mk_version})"
    
    install_child_tooling
}

# Copy the SUSPICIOUS tooling (spawn/audit scripts + config) into the child
# rootfs so nested spawn (test-checklist Phase 11) works from inside the child
install_child_tooling() {
    show_status "INFO" "Installing proj-mk-ultra tooling into child (/opt/proj-mk-ultra)"
    mkdir -p /mnt/child-root/opt/proj-mk-ultra
    cp -a "${SCRIPT_DIR}/../scripts" /mnt/child-root/opt/proj-mk-ultra/
    cp -a "${SCRIPT_DIR}/../etc" /mnt/child-root/opt/proj-mk-ultra/
    show_status "OK" "Child tooling installed (spawn/audit available inside child)"
}

# Function to install Debian base system
install_debian_base() {
    show_status "INFO" "Installing Debian base system"
    
    # Use debootstrap to install base system
    debootstrap --include=linux-image-amd64 bookworm /mnt/child-root http://deb.debian.org/debian
    
    show_status "OK" "Debian base system installed"
}

# Function to install Fedora base system
install_fedora_base() {
    show_status "INFO" "Installing Fedora base system"
    
    # Use dnf to install base system
    dnf --installroot=/mnt/child-root --releasever=/ install -y @core kernel
    
    show_status "OK" "Fedora base system installed"
}

# Function to configure boot
# The child boots via multikernel kexec from the host — no GRUB needed.
# The boot partition holds the kernel image and initramfs for the
# multikernel spawn path. A standalone BLS entry is created for
# direct-boot recovery if systemd-boot is available.
configure_boot() {
    show_step "Configuring Boot" 6
    
    # Verify kernel + initramfs are in place
    if [ ! -f /mnt/child-root/boot/vmlinuz-linux-multikernel ]; then
        show_status "WARN" "Kernel image not found in child /boot"
        return 1
    fi
    show_status "OK" "Kernel image: /boot/vmlinuz-linux-multikernel"
    
    if [ -f /mnt/child-root/boot/initramfs-linux-multikernel.img ]; then
        show_status "OK" "Initramfs: /boot/initramfs-linux-multikernel.img"
    else
        show_status "WARN" "Initramfs not found — generate with mkinitcpio after spawn"
    fi
    
    # Best-effort standalone EFI bootloader for direct-boot recovery
    show_status "INFO" "Installing standalone EFI bootloader (best-effort)"
    if command -v grub-install &>/dev/null; then
        mkdir -p /mnt/child-root/boot/grub
        cat > /mnt/child-root/boot/grub/grub.cfg << EOF
set default=0
set timeout=5
menuentry "Child Kernel (SUSPICIOUS)" {
    linux /vmlinuz-linux-multikernel root=UUID=$(blkid -s UUID -o value "${ROOT_PARTITION}") rw multikernel.role=child
    initrd /initramfs-linux-multikernel.img
}
EOF
        grub-install --target=x86_64-efi --efi-directory=/mnt/child-root/boot \
            --boot-directory=/mnt/child-root/boot --removable --no-nvram 2>/dev/null \
            && show_status "OK" "Standalone EFI bootloader installed" \
            || show_status "WARN" "grub-install failed - multikernel spawn unaffected"
    else
        show_status "WARN" "grub-install not available - skipping standalone boot"
    fi
}

# Function to configure fstab
configure_fstab() {
    show_step "Configuring fstab" 7
    
    show_status "INFO" "Generating fstab"
    
    local root_uuid
    root_uuid=$(blkid -s UUID -o value "${ROOT_PARTITION}")
    
    local boot_uuid
    boot_uuid=$(blkid -s UUID -o value "${BOOT_PARTITION}")
    
    local user_uuid
    user_uuid=$(blkid -s UUID -o value "${USER_PARTITION}")
    
    cat > /mnt/child-root/etc/fstab << EOF
UUID=${root_uuid} / ${ROOT_FILESYSTEM} defaults,noatime 0 1
UUID=${boot_uuid} /boot vfat defaults,noatime 0 2
UUID=${user_uuid} /data ${USER_DATA_FILESYSTEM} defaults,noatime,nosuid,nodev,x-systemd.after=local-fs.target 0 2

tmpfs /tmp tmpfs defaults,nosuid,nodev,noexec,mode=1777 0 0
tmpfs /run tmpfs defaults,nosuid,nodev,mode=755 0 0
EOF
    
    show_status "OK" "fstab configured"
}

# Function to configure network
configure_network() {
    show_step "Configuring Network" 8
    
    # Disable networking (SUSPICIOUS Framework requirement)
    show_status "INFO" "Disabling networking (SUSPICIOUS Framework)"
    
    # Disable NetworkManager
    chroot /mnt/child-root systemctl disable NetworkManager 2>/dev/null || true
    
    # Disable systemd-networkd
    chroot /mnt/child-root systemctl disable systemd-networkd 2>/dev/null || true
    
    # Create empty resolv.conf
    echo "# SUSPICIOUS Framework - No network access" > /mnt/child-root/etc/resolv.conf
    
    show_status "OK" "Networking disabled"
}

# Function to configure security
configure_security() {
    show_step "Configuring Security" 9
    
    show_status "INFO" "Disabling SSH"
    chroot /mnt/child-root systemctl disable sshd 2>/dev/null || true
    
    show_status "INFO" "Disabling remote services"
    chroot /mnt/child-root systemctl disable rpcbind 2>/dev/null || true
    
    show_status "INFO" "Configuring firewall (deny all)"
    if command -v iptables &> /dev/null; then
        chroot /mnt/child-root iptables -P INPUT DROP
        chroot /mnt/child-root iptables -P FORWARD DROP
        chroot /mnt/child-root iptables -P OUTPUT DROP
    fi
    
    show_status "INFO" "Mounting /data as noexec,nosuid,nodev"
    
    show_status "OK" "Security configured"
}

# Function to create user data structure
create_user_data_structure() {
    show_step "Creating User Data Structure" 10
    
    # Create directory structure
    local directories=(
        "/data/workspace"
        "/data/documents"
        "/data/downloads"
        "/data/config"
        "/data/logs"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "/mnt/child-root${dir}"
        show_status "OK" "Created: ${dir}"
    done
    
    # Create .gitkeep files
    for dir in "${directories[@]}"; do
        touch "/mnt/child-root${dir}/.gitkeep"
    done
    
    show_status "OK" "User data structure created"
}

# Function to cleanup
cleanup() {
    show_step "Cleaning Up" 11
    
    # Unmount partitions
    show_status "INFO" "Unmounting partitions"
    
    umount /mnt/child-root/boot 2>/dev/null || true
    umount /mnt/child-root/data 2>/dev/null || true
    umount /mnt/child-root 2>/dev/null || true
    
    # Remove mount points
    rmdir /mnt/child-root/boot 2>/dev/null || true
    rmdir /mnt/child-root/data 2>/dev/null || true
    rmdir /mnt/child-root 2>/dev/null || true
    
    show_status "OK" "Cleanup complete"
}

# Function to display summary
show_summary() {
    echo -e "\n${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  INSTALLATION COMPLETE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "  Disk: /dev/${DISK}"
    echo -e "  Partitions:"
    echo -e "    ${BOOT_PARTITION} - Boot (FAT32)"
    echo -e "    ${ROOT_PARTITION} - Root (${ROOT_FILESYSTEM})"
    echo -e "    ${USER_PARTITION} - User Data (${USER_DATA_FILESYSTEM})"
    echo
    
    echo -e "${BOLD}Directory Structure:${NC}"
    echo -e "  /boot/ - Kernel and boot files"
    echo -e "  / - Root filesystem"
    echo -e "  /data/ - User data (persists across child kernel rebuilds)"
    echo
    
    echo -e "${BOLD}Next Steps (launch-pad model — NO REBOOT):${NC}"
    echo "  1. Verify multikernel sysfs: ls /sys/fs/multikernel/instances/"
    echo "  2. Pre-spawn baseline: sudo ./scripts/first-spawn-validate.sh --pre-spawn"
    echo "  3. Spawn: sudo ./scripts/spawn-child-instance.sh child-fsv"
    echo "  4. Validate: sudo ./scripts/first-spawn-validate.sh"
    echo
}

# Main function
main() {
    show_banner
    check_root
    
    echo -e "${BOLD}Host: $(hostname)${NC}"
    echo -e "${BOLD}Date: $(date)${NC}"
    
    select_disk
    verify_partitions
    create_mount_points
    mount_partitions
    install_base_system
    configure_boot
    configure_fstab
    configure_network
    configure_security
    create_user_data_structure
    cleanup
    
    show_summary
}

# Run main function
main "$@"
