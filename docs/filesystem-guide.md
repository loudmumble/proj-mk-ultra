# Filesystem Guide

## Overview

PROJ-MK-ULTRA supports multiple filesystems for child kernel instances. Each filesystem has different security properties, performance characteristics, and use cases.

## Host Prerequisites (Before Filesystem Selection)

### Hardware Requirements
- **IOMMU**: Intel VT-d or AMD-Vi enabled in BIOS/UEFI
- **Kernel Parameters**: `intel_iommu=on` or `amd_iommu=on` in GRUB/bootloader
- **VFIO Driver**: `modprobe vfio-pci` for device passthrough
- **Multiple Disks**: Host disk + child disk (SD card or secondary drive)

### Disk Identification
```bash
# List all disks
lsblk

# Identify host disk (where / is mounted - DO NOT FORMAT)
df -h /

# Identify child disk (secondary - WILL BE FORMATTED)
# Typically /dev/sdb, /dev/sdc, etc.
```

### Config File Keys
Edit `etc/proj-mk-ultra.conf` before running setup:
```bash
TARGET_DISK="sdb"           # Child disk device (without /dev/)
CHILD_ROOT_DEVICE="/dev/sdb2"    # For auto-destroy/preserve-data
CHILD_DATA_DEVICE="/dev/sdb3"    # For user data persistence
```

### Safety Notes
- **Host disk is never formatted** - scripts auto-detect and exclude root device
- **Child disk is destroyed** - all data will be lost
- **User data persists** - `/dev/sdb3` survives child root rebuilds
- **IOMMU boundary** - hardware-enforced isolation between host/child

## Filesystem Options

### ext4

**Type:** Traditional journaled filesystem

**Security Properties:**
- Mature and well-tested
- Journal provides crash recovery
- No built-in checksumming
- Well-understood attack surface

**Performance:**
- Good general-purpose performance
- Efficient for small files
- Moderate memory usage

**Use Cases:**
- Default choice for most users
- Stable, predictable behavior
- When you need maximum compatibility

### btrfs

**Type:** Copy-on-write (CoW) filesystem

**Security Properties:**
- Built-in checksumming (detects corruption/tampering)
- Snapshot capability (rollback on anomaly)
- Copy-on-write prevents partial writes
- Subvolume isolation

**Performance:**
- Higher memory usage
- Snapshot creation is fast
- CoW can cause fragmentation
- Better for large files

**Use Cases:**
- When you need corruption detection
- When you want rollback capability
- Advanced security requirements
- When disk space is abundant

### xfs

**Type:** High-performance filesystem

**Security Properties:**
- Journal provides crash recovery
- No built-in checksumming
- Good parallel I/O performance
- Mature and stable

**Performance:**
- Excellent for large files
- Good parallel I/O
- Low memory overhead
- Fast metadata operations

**Use Cases:**
- When you need high throughput
- Large file workloads
- When performance is critical
- Enterprise environments

### f2fs

**Type:** Flash-optimized filesystem

**Security Properties:**
- Designed for NAND flash
- No built-in checksumming
- Good wear leveling
- Efficient garbage collection

**Performance:**
- Optimized for SSDs/flash
- Lower write amplification
- Better lifespan on flash
- Good random I/O

**Use Cases:**
- When using SD cards or USB drives
- Flash-based storage
- When extending device lifespan matters
- Mobile/embedded systems

### zfs

**Type:** Advanced filesystem with integrated volume management

**Security Properties:**
- Built-in checksumming (detects corruption/tampering)
- Snapshot capability (rollback on anomaly)
- Copy-on-write prevents partial writes
- Data integrity verification
- RAID support (mirror, RAIDZ1-3)

**Performance:**
- Higher memory usage (recommended: 1GB per TB of storage)
- Excellent for large datasets
- Good parallel I/O
- Deduplication available (memory-intensive)

**Use Cases:**
- Advanced security requirements
- Data integrity critical workloads
- When checksumming is essential
- Enterprise environments
- When RAID is needed

**Note:** ZFS requires additional setup and is recommended for advanced users only.

## Leapfrog Filesystem Diversity

### Concept

Using different filesystems between host and child kernels creates **filesystem diversity**. This makes poisoned metadata payloads incompatible across filesystem boundaries.

### How It Works

```
Host: ext4 (on /dev/sda)
Child: btrfs (on /dev/sdb2)
Grandchild: xfs (on /dev/sdb2)
```

A payload crafted to exploit ext4 metadata structures will fail on btrfs because the on-disk formats are completely different.

### Security Benefits

1. **Metadata incompatibility** - Poisoned ext4 metadata doesn't work on btrfs
2. **Attack surface reduction** - Each filesystem has different vulnerabilities
3. **Defense in depth** - Multiple layers of protection
4. **Detection difficulty** - Attackers must target specific filesystem

### Performance Costs

1. **Multiple filesystem drivers** - Kernel must load more modules
2. **Management complexity** - Different tools for each filesystem
3. **Backup complexity** - Different backup strategies needed

### Configuration

In `proj-mk-ultra.conf`:
```
CHILD_LEAPFROG_FS_ENABLE="true"
CHILD_LEAPFROG_FS="btrfs"
CHILD_LEAPFROG_ALT="xfs"
```

## Security Level Presets

### Basic

- Same filesystem for all partitions
- No leapfrog
- No cross-distro
- Simplest configuration

### Intermediate

- Leapfrog enabled
- User selects filesystems
- No cross-distro
- Good balance of security and complexity

### Advanced

- Leapfrog enabled
- User selects filesystems for each generation
- Cross-distro optional (recommended for maximum isolation)
- btrfs snapshots optional (if using btrfs)
- Maximum isolation and security

## Recommendations

### For Most Users

- Use **ext4** for host and child
- Skip leapfrog (adds complexity)
- Use **basic** security level

### For Security Researchers

- Use **ext4** for host
- Use **btrfs** for child (snapshots)
- Enable leapfrog
- Use **intermediate** or **advanced** security level

### For Testing

- Use **ext4** for host
- Use **f2fs** for SD card testing
- Enable leapfrog if testing security features
- Use **basic** or **intermediate** security level

### For Production

- Use **ext4** or **xfs** for host
- Use **btrfs** for child (rollback capability)
- Enable leapfrog
- Use **advanced** security level
