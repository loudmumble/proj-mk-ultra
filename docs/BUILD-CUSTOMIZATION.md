# Build Customization Guide

## Hardware Specs and Safe Deviations for PROJ-MK-ULTRA

**Version:** 1.0.0
**Date:** September 6, 2026
**Audience:** End-users building a PROJ-MK-ULTRA deployment

---

## 1. Reference Hardware Configuration

This is the hardware setup the project was built and tested against. Every script default, every partition size, and every kernel parameter traces back to these specs.

| Component | Specification | Where It Appears in Code |
|-----------|--------------|--------------------------|
| **Architecture** | x86_64 only | `2_setup.sh` phase 1 rejects anything else |
| **CPU** | Host keeps CPUs 0-3, child takes all others | Config `CHILD_CPU_MASK` (default `0xFFFFFFF0`); the DTB `cpus` cell is built from the physical APIC IDs resolved from it (with the pool baseline-record fallback once CPUs are parked) |
| **RAM** | 128GB total (reference: ZONE_MOVABLE 116GB, child pool 81917M, ~36GB slack returns to host) | Boot param `movablecore=116G`; config `CHILD_MEMORY_SIZE` drives the baseline/DTB size cells; find your machine's ceiling with `scripts/probe-pool-ceiling.sh` |
| **Host Disk** | Dedicated physical disk (e.g., /dev/sda) | `partition-disk.sh` excludes root device from selection |
| **Child Disk** | Dedicated physical disk (e.g., /dev/sdb), 25GB+ | `partition-disk.sh` creates 3 partitions on secondary disk |
| **Bootloader** | systemd-boot (Arch Linux default) | `test-checklist.md` provides systemd-boot kernel parameter instructions |
| **IOMMU** | Intel VT-d or AMD-Vi, enabled in BIOS | `verify-iommu.sh` checks groups, kernel params, DMA protection |
| **VFIO** | vfio-pci driver loaded | `2_setup.sh` checks `lsmod \| grep vfio` |
| **Kernel** | Multikernel Linux v7.0-mk2 (Linux 7.0 base) | `README.md` references `git checkout v7.0-mk2` |
| **Host Filesystem** | btrfs (this build; configurable) | `proj-mk-ultra.conf`: `CORE_HOST_FILESYSTEM="btrfs"` |
| **Child Filesystem** | ext4 (configurable, supports btrfs/xfs/zfs/f2fs) | `2_setup.sh` phase 2 offers filesystem selection |
| **Init System** | systemd | `2_setup.sh` errors if `pidof systemd` fails |

### Child Disk Partition Layout

Created by `partition-disk.sh` on the secondary disk:

```
/dev/sdX1  -  Boot       FAT32   512MB    ESP flag set
/dev/sdX2  -  Root       ext4    20GB     Ephemeral, destroyed on anomaly
/dev/sdX3  -  User Data  ext4    100%     Persists across child rebuilds
```

The same layout is used for SD card testing via `sd-card-2_setup.sh`.

---

## 2. Design Considerations and Rationale

Each design choice below explains what was chosen, why it was chosen, how it affects the scripts, and what you can safely change.

### 2a. Separate Physical Disks (Not Partitions on Same Disk)

**What:** Host OS lives on one physical disk. Child kernel lives on a completely separate disk.

**Why:** The SUSPICIOUS Framework requires a hardware-enforced boundary between trust domains. Two partitions on the same disk share the same SATA/NVMe controller, the same IOMMU group, and the same DMA path. That means a compromised child kernel could theoretically issue DMA requests against the host partition. Separate disks on separate controllers (or at minimum, separate IOMMU groups) close this hole.

**How it affects scripts:** `partition-disk.sh` explicitly detects the root device and excludes it from the selection list. `2_setup.sh` requires at least 2 disks and fails if only one is found. `install-child-kernel.sh` mounts the child root at `/mnt/child-root`, never touching the host disk.

**What you can change:** You can use an SD card instead of a second internal disk (`INSTALL_TARGET="sd-card"`). You can also use a partition on the host disk (`INSTALL_TARGET="host-partition"`), but this weakens the hardware boundary and is not recommended for production.

### 2b. systemd-boot Over GRUB

**What:** The reference platform uses systemd-boot, not GRUB.

**Why:** Arch Linux ships systemd-boot as its default for UEFI systems. It's simpler to configure (one file per boot entry in `/boot/loader/entries/`), faster (no GRUB module loading), and easier to script against (plain text files, no `grub-mkconfig` regeneration step).

**How it affects scripts:** `test-checklist.md` gives systemd-boot instructions for adding IOMMU kernel parameters (edit `/boot/loader/entries/YOUR-ENTRY.conf` directly). The `install-child-kernel.sh` script currently writes a GRUB config at `/mnt/child-root/boot/grub/grub.cfg` as a fallback, but the primary path assumes systemd-boot entries on the host.

**What you can change:** GRUB works. The test checklist includes GRUB instructions for kernel parameters. If you use GRUB, you'll need to run `grub-mkconfig` after any kernel parameter change instead of editing a `.conf` file directly.

### 2c. ext4 as Default Filesystem

**What:** ext4 is the default for both host and child partitions.

**Why:** ext4 is the most mature Linux filesystem. It needs no special kernel modules beyond what every distro ships, no userspace utilities for basic operation, and has the widest recovery tool support. For a security-focused project where the child root gets destroyed and rebuilt regularly, simplicity wins.

**How it affects scripts:** `partition-disk.sh` calls `mkfs.ext4` by default. `setup-filesystem-isolation.sh` runs `e2fsck` for filesystem checks. `auto-destroy.sh` mounts the user data partition as ext4 when preserving data.

**What you can change:** `2_setup.sh` offers btrfs, xfs, f2fs, and zfs (advanced level) as alternatives. btrfs adds CoW snapshots and checksumming. xfs is better for large files. zfs adds RAID and superior integrity checking. Each requires its own userspace tools (`btrfs-progs`, `xfsprogs`, `zfs-utils`). If you pick btrfs, the optional snapshot automation becomes available.

### 2d. Config-Driven Device Paths

**What:** Disk device paths (`TARGET_DISK`, `CHILD_BOOT_DEVICE`, `CHILD_ROOT_DEVICE`, `CHILD_DATA_DEVICE`) are empty by default in the config file.

**Why:** Device names are not portable. `/dev/sdb` on one machine might be `/dev/nvme1n1` on another. Hardcoding paths would break on any hardware that doesn't match the reference exactly.

**How it affects scripts:** `partition-disk.sh` and `install-child-kernel.sh` check `TARGET_DISK` first. If set, they use it. If empty, they fall back to interactive selection, listing all non-root disks and letting the user pick. `auto-destroy.sh` uses `CHILD_DATA_DEVICE` with a fallback to `/dev/sdb3`.

**What you can change:** Set these keys in `etc/proj-mk-ultra.conf` before running scripts to skip interactive prompts. Use `lsblk` to identify your disks. Never set `TARGET_DISK` to your host disk.

### 2e. Multikernel Kernel at /opt/multikernel/linux

**What:** The multikernel kernel source lives at `/opt/multikernel/linux`.

**Why:** `/usr/src/` is the standard Linux convention for kernel source trees. Every kernel build tool, every `make modules_install`, and every package manager expects source in this location.

**How it affects scripts:** `multi-kernel-update.sh` hardcodes `MULTIKERNEL_SRC="/opt/multikernel/linux"` and exits if the directory doesn't exist. The build process requires `CONFIG_MULTIKERNEL=y` in the kernel config.

**What you can change:** The path itself is fixed in `multi-kernel-update.sh`. If you want a different location, you'd need to edit that script. There's no config key for this path.

### 2f. Child Kernel Sync via rsync

**What:** `sync-child-kernel.sh` uses rsync to copy kernel files, modules, and firmware from the host to the child partition.

**Why:** The child kernel runs the same multikernel build as the host. Keeping them in sync means the child always has the same kernel image, modules, and firmware. rsync handles incremental updates efficiently and the `--delete` flag removes stale files.

**How it affects scripts:** The script mounts the child root and boot partitions, rsyncs `/boot/`, `/lib/modules/`, and `/lib/firmware/`, then verifies the sync by checking file existence. After syncing, the child kernel needs a reboot to pick up changes.

**What you can change:** The sync is one-directional (host to child). You can't sync from child to host. The script always syncs the currently running kernel version (`uname -r`). There's no config key to change this behavior.

### 2g. Btrfs Snapshots as Optional

**What:** btrfs snapshot automation is disabled by default (`BTRFS_SNAPSHOT_ENABLE="false"`).

**Why:** Snapshots are a convenience feature, not a security requirement. The SUSPICIOUS Framework's security model doesn't depend on CoW snapshots. The auto-destroy mechanism already handles compromise recovery by rebuilding the child root from scratch. Snapshots just make that recovery faster.

**How it affects scripts:** The option only appears in `2_setup.sh` when the security level is "advanced" and either the host or child filesystem is btrfs. When enabled, `btrfs-snapshot.sh` provides create/list/rollback operations.

**What you can change:** Enable it if you're using btrfs. Set `BTRFS_SNAPSHOT_KEEP` to control retention (default: 5 snapshots). This has no effect on SUSPICIOUS Framework compliance.

### 2h. Cross-Distro Support via debootstrap/dnf

**What:** Child instances can run Debian, Ubuntu, Fedora, or RHEL instead of Arch.

**Why:** Some users need specific distro packages or environments in the child kernel. Cross-distro support pulls the rootfs from remote mirrors using `debootstrap` (Debian/Ubuntu) or `dnf --installroot` (Fedora/RHEL). No local ISO needed.

**How it affects scripts:** `2_setup.sh` checks for `debootstrap` and `dnf` during system detection when `CROSS_DISTRO_ENABLE="true"`. `install-child-kernel.sh` has separate `install_debian_base()` and `install_fedora_base()` functions alongside the default `install_arch_base()`.

**What you can change:** Set `CROSS_DISTRO_ENABLE="true"` and pick your `CHILD_DISTRO` (debian, ubuntu, fedora, rhel). You need the corresponding tool installed on the host. This is only available at the "advanced" security level.

### 2i. Security Level Presets (Basic/Intermediate/Advanced)

**What:** Three preset configurations that control which features are available.

**Why:** Not every user needs every hardening feature. Basic gets you running quickly. Intermediate adds filesystem diversity. Advanced adds cross-distro and snapshot options. This progressive approach lets users match complexity to their threat model.

**How it affects scripts:** `2_setup.sh` phase 2 branches on `SECURITY_LEVEL`. Basic skips leapfrog and cross-distro prompts. Intermediate enables leapfrog. Advanced enables everything. The presets only affect which options are presented, not the underlying security mechanisms (IOMMU, capability dropping, network isolation are always on).

**What you can change:** Pick a higher level for more options. You can always change the level later by editing the config or re-running `2_setup.sh`.

### 2j. Host CAN Mount Child Data Partition

**What:** The host kernel can mount `/dev/sdb3` (child user data) at any time.

**Why:** This is intentional. The user data partition needs to survive child kernel rebuilds. The host mounts it for backup, restore, and data preservation during auto-destroy. `auto-destroy.sh` explicitly mounts the user data partition and verifies file integrity before destroying the compromised child kernel.

**How it affects scripts:** `preserve_user_data()` in `auto-destroy.sh` mounts the partition at `/mnt/preserved-data`. `setup-filesystem-isolation.sh` adds an fstab entry with `nosuid,nodev,noexec` mount options to limit what can be done with the mounted data.

**What you can change:** Nothing. This is a design requirement. If you block the host from mounting the child data partition, auto-destroy can't preserve your files.

### 2k. Child CANNOT Access Host Disk

**What:** The child kernel has no access to the host disk (`/dev/sda`).

**Why:** This is the core hardware boundary. IOMMU groups isolate the child disk's controller from the host disk's controller. Even if the child kernel is fully compromised, it can't issue DMA requests or send commands to the host disk.

**How it affects scripts:** `verify-iommu.sh` checks that IOMMU groups exist and contain devices. The DTS configuration in `auto-destroy.sh` assigns the child kernel its own block device (`device = "${CHILD_ROOT_DEVICE}"`) with `type = "dedicated"`.

**What you can change:** Nothing. If the child can access the host disk, the isolation model is broken. Don't pass through the host disk's controller to the child.

### 2l. OverlayFS Excluded

**What:** `CONFIG_OF_OVERLAY` is not used in this project.

**Why:** `CONFIG_OF_OVERLAY` is a Device Tree overlay mechanism for hardware description, not a filesystem overlay. It's unrelated to OverlayFS. The project uses Device Tree overlays in `auto-destroy.sh` to define multikernel instances, but this is kernel device tree syntax, not filesystem layering.

**How it affects scripts:** The DTS overlay in `auto-destroy.sh` uses `/plugin/` and `__overlay__` syntax to inject instance definitions into the kernel's device tree at runtime.

**What you can change:** Nothing to change. This isn't a configurable option.

### 2m. NVIDIA / GPU in Child Kernel (Host Stays Clean)

**What:** Host kernel uses nouveau (open-source) only. `nvidia-open-dkms` (open-source kernel module, GPL-compatible) is loaded ONLY inside the child kernel instance.

**Why:** The SUSPICIOUS Framework requires the host kernel to maintain `tainted = 0`. Loading `nvidia-open-dkms` (open-source kernel module, GPL-compatible) sets two taint bits: Bit 12 (O = 4096, out-of-tree module), Bit 13 (E = 8192, unsigned module), totaling `tainted = 12288`. Because it is GPL-compatible, bit 0 (proprietary) is NOT set. By loading NVIDIA only in the ephemeral child kernel, the taint is born and dies with each child instance lifecycle.

**How it affects scripts:**
- `monitor-boot-integrity.sh` reads `/proc/sys/kernel/tainted` on the HOST — must always be `0`
- If host `tainted != 0` → anomaly detected → child destroyed immediately
- Child kernel loads NVIDIA via `modprobe nvidia` after boot — child becomes tainted=12288
- Child runs `llama-server` (llama.cpp) for local GPU inference
- Child launches `libvirt/QEMU` VM for development work
- When child is destroyed, NVIDIA taint disappears with it

**What you can change:**
- You CAN load NVIDIA in the child kernel — this is the intended architecture
- You CAN use GPU passthrough (VFIO) to pass NVIDIA GPU to VM inside child
- You CANNOT load NVIDIA on the host — this breaks the taint invariant
- You CAN use nouveau on the host for display output (recommended)

**Hardware requirement:** Host MUST have a display output that works with nouveau (or a secondary GPU). If your only GPU requires NVIDIA proprietary drivers (no nouveau support), you'll need a secondary GPU or headless setup for the host. NOTE: We recommend `nvidia-open-dkms` in the child kernel (GPL-compatible, taint=12288) rather than closed-source `nvidia` drivers (taint=12289).

---

## 3. Installation Locations and Why

Every path the project uses, and the reason for that location.

| Path | Purpose | Why This Location |
|------|---------|-------------------|
| `/opt/multikernel/linux/` | Multikernel kernel source tree | Standard Linux convention for kernel sources. `make modules_install` and package managers expect this. Hardcoded in `multi-kernel-update.sh`. |
| `/boot/loader/entries/` | systemd-boot entry files | systemd-boot reads `.conf` files from this directory. One file per boot entry. Plain text, no regeneration step needed. |
| `/opt/suspicious/` | SUSPICIOUS Framework scripts and data | FHS 3.0 specifies `/opt/` for add-on application software. Keeps framework files separate from system files. |
| `/opt/suspicious/forensic/` | Forensic evidence tarballs | `auto-destroy.sh` creates timestamped evidence archives here. Separated from scripts to prevent accidental deletion. |
| `/opt/suspicious/updates/` | Update staging area | `setup-updates.sh` uses this for downloaded packages and update state. |
| `/etc/proj-mk-ultra.conf` | Centralized configuration | `/etc/` is the standard location for system-wide configuration. All scripts source this single file. |
| `/sys/fs/multikernel/` | Multikernel sysfs interface | Kernel-managed virtual filesystem. Created by the multikernel module, not by userspace. Instance directories appear under `instances/`. |
| `/var/log/proj-mk-ultra/` | Setup and update logs | `2_setup.sh` creates timestamped logs here. Standard `/var/log/` convention. |
| `/var/log/suspicious-*.log` | Runtime service logs | Individual services (auto-destroy, sync, updates) each write their own log file. Uses `logger` for syslog integration too. |
| `/var/lib/proj-mk-ultra/` | Setup state files | `2_setup.sh` stores detection results here. `/var/lib/` is the FHS location for persistent application state. |
| `/var/backups/proj-mk-ultra/` | Configuration backups | `2_setup.sh` creates this during initialization. Separate from `/var/lib/` to distinguish backups from state. |
| `/var/backup/multikernel-kernels/` | Kernel image backups | `multi-kernel-update.sh` archives previous kernel images before updates. |
| `/mnt/child-root/` | Temporary mount point for child root | Used during installation and sync operations. Not a persistent mount. Scripts mount, do work, unmount. |
| `/mnt/preserved-data/` | Temporary mount for data preservation | `auto-destroy.sh` mounts child user data here during incident response. |

---

## 4. Configurable Deviations (Safe to Change)

Every key in `etc/proj-mk-ultra.conf`, what it controls, and what happens if you get it wrong.

Config keys use `UPPER_SNAKE_CASE` names directly in the file - the config is sourced as bash by every script, so keys MUST be valid bash variable names (no hyphens).

### Disk Configuration

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `TARGET_DISK` | Which disk to partition for child | `"sdb"` (this build) | Any non-root disk name (sdb, nvme1n1, mmcblk0; `/dev/` prefix accepted) | Set to host disk = data loss | None, but wrong value is catastrophic |
| `CHILD_BOOT_DEVICE` | Child boot partition path | `""` (auto-detect) | `/dev/sdb1`, `/dev/nvme1n1p1` | Wrong partition = boot failure | None |
| `CHILD_ROOT_DEVICE` | Child root partition path | `""` (auto-detect) | `/dev/sdb2`, `/dev/nvme1n1p2` | Wrong partition = child won't boot | None |
| `CHILD_DATA_DEVICE` | Child user data partition path | `""` (auto-detect) | `/dev/sdb3`, `/dev/nvme1n1p3` | Wrong partition = data loss during preserve | None |

### Child Hardware Assignment & Memory Sequestration

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `CHILD_CPU_MASK` | Hex bitmask of CPUs owned by the child | `"0xFFFFFFF0"` (host keeps CPUs 0-3) | Any hex mask; extra bits beyond the CPU count are harmless | Mask excluding all CPUs = child can't boot | **Required** - CPU partitioning is a hardware boundary |
| `CHILD_MEMORY_SIZE` | Dedicated RAM the child owns | `"112G"` (generic fallback; reference build 81917M — derive YOUR ceiling with probe-pool-ceiling.sh) | Any size <= the machine's pool ceiling (probe-pool-ceiling.sh) | Larger than reservation = spawn preflight aborts | **Required** - memory carve is the isolation boundary for RAM |
| `PASSTHROUGH_PCI_DEVICES` | PCI slots handed to the child | `"01:00.0"` (GPU — display handoff) | Space-separated list of slots (`lspci -nn`); append `00:14.0` (USB) for USB-root deployments | Passing the controller hosting the host NVMe = host root exposed | None - 01:00.0 (GPU) never hosts the boot NVMe |
| `MEMORY_RESERVATION_ACKNOWLEDGED` | Override the spawn ZONE_MOVABLE preflight | `"false"` | `"true"` only for platforms reserving memory by another mechanism | Blind override with unreserved memory = silent corruption | Set only with explicit justification |
| `CHILD_KERNEL_PATH` | Host-side multikernel kernel image | `""` (auto-discover newest `/boot/*mk2*` build) | Full path | Stale path = spawn falls back to discovery | None |
| `CHILD_INITRD_PATH` | Host-side initramfs paired with the kernel | `""` (auto-discover sibling `initrd`) | Full path | Wrong pair = child boot failure | None |

**Memory sequestration is mandatory.** Peripherals passed to the child are hardware-enforced by the IOMMU - the child's devices physically cannot DMA into host memory. Memory has no IOMMU equivalent: both kernels are ring-0 peers that can decode the entire RAM address space, so the only boundary is the host allocator's promise to never own the child's frames. That promise must be made at boot, before the host allocator touches anything:

```
# reference: 128GB host; ZONE_MOVABLE=116G = child pool (81917M) + 36G contig slack
movablecore=116G
```

Add to the multikernel entry's `options` line in `/boot/loader/entries/`, reboot, verify:

```bash
grep -A8 'zone.*Movable' /proc/zoneinfo | grep present    # reservation acknowledged by the zone split
sudo ./scripts/probe-pool-ceiling.sh   # the pool ceiling is machine-dependent
free -g                   # host sees ~45GB available after the baseline
```

Notes:
- Consumer memory controllers interleave channels, so the split is by **address range**, not physical DIMM - the top 116GB range is striped across all sticks. Isolation is unaffected: after the baseline, the host never allocates those frames and the child's page tables map them exclusively. DIMM-pinning only exists on NUMA/CXL server platforms.
- Keep VM RAM allocations well under the host's ~45GB post-baseline share (reference: 8GB VM, verified from real deployment) so it is never exhausted while a child runs.
- Changing a VM's allocation in virt-manager requires the VM powered OFF — the Memory field is a cold change, not a live adjustment.
- Hibernate/suspend with a memory carve is untested - verify before relying on it.
- Adding `00:14.0` (USB) hands the child the keyboard/mouse/SD reader: the host console goes keyboard-less while the child runs and reclaims it when the child exits. VMs are unaffected (virtio input does not use host USB).

### Filesystem Configuration

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `CORE_HOST_FILESYSTEM` | Host and child root/data filesystem type | `"ext4"` | `btrfs`, `xfs`, `f2fs`, `zfs` | Missing mkfs tool for chosen FS | None. All supported FS maintain isolation |
| `CHILD_LEAPFROG_FS_ENABLE` | Enable filesystem diversity between generations | `"false"` | `"true"` | Requires intermediate+ security level | Enhances compliance when true |
| `CHILD_LEAPFROG_FS` | Child filesystem (when leapfrog enabled) | `"btrfs"` | Any FS different from host | Same as host = diversity defeated | Enhances compliance |
| `CHILD_LEAPFROG_ALT` | Grandchild filesystem (when leapfrog enabled) | `"xfs"` | Any FS different from child | Same as child = diversity defeated | Enhances compliance |

### Partition Sizing

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `CHILD_BOOT_SIZE` | Boot partition size | `"512M"` | `256M`-`1G` | Too small for kernel+initramfs | None |
| `CHILD_ROOT_SIZE` | Root partition size | `"20G"` | `10G`-`50G` | Too small for base system + packages | None |
| `CHILD_DATA_SIZE` | User data partition size | `"100%"` | Any percentage or fixed size | Fixed sizes are clamped to the space left after boot+root (1MiB GPT tail margin kept) | None |

Note: `partition-disk.sh` reads `CHILD_BOOT_SIZE`, `CHILD_ROOT_SIZE`, and `CHILD_DATA_SIZE` directly from the config - these keys are the single source of truth for partition sizes.

### Security Settings

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `SECURITY_LEVEL` | Feature preset | `"basic"` | `intermediate`, `advanced` | Invalid value = falls back to basic | None, all levels maintain core compliance |
| `MODULE_SIGNING_ENFORCE` | Reject unsigned kernel modules | `"true"` | `"false"` (not recommended) | `false` allows unsigned module loading | **Required true for full compliance** |
| `IOMMU_VERIFY` | Verify IOMMU during prevention phase | `"true"` | `"false"` (not recommended) | `false` skips hardware isolation check | **Required true for full compliance** |
| `CAPABILITY_DROPPING` | Drop all capabilities in child | `"true"` | `"false"` (not recommended) | `false` gives child elevated privileges | **Required true for full compliance** |
| `FILESYSTEM_ISOLATION` | Read-only root, tmpfs, mount restrictions | `"true"` | `"false"` (not recommended) | `false` allows child to modify system files | **Required true for full compliance** |
| `NETWORK_ISOLATION` | No network access in child | `"true"` | `"false"` (not recommended) | `false` gives child network access | **Required true for full compliance** |

### Detection Settings

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `BOOT_INTEGRITY_MONITOR` | Hash boot files, alert on change | `"true"` | `"false"` | `false` = no boot tampering detection | Recommended true |
| `HARDWARE_ISOLATION_MONITOR` | Monitor IOMMU/VFIO status | `"true"` | `"false"` | `false` = no hardware boundary alerts | Recommended true |
| `SYSFS_ACCESS_MONITOR` | Log sysfs access attempts | `"true"` | `"false"` | `false` = blind to sysfs probing | Recommended true |
| `MODULE_LOADING_MONITOR` | Log/block unauthorized module loads | `"true"` | `"false"` | `false` = blind to rootkit loading | Recommended true |
| `BEHAVIORAL_ANOMALY_DETECTION` | Detect unusual process/resource patterns | `"true"` | `"false"` | `false` = no behavioral baseline | Recommended true |

### Response Settings

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `AUTO_DESTROY_ON_DETECTION` | Destroy child kernel on anomaly | `"true"` | `"false"` | `false` = compromised child keeps running | **Required true for full compliance** |
| `PRESERVE_USER_DATA` | Save user data before destroy | `"true"` | `"false"` | `false` = user data lost on destroy | Recommended true |
| `FORENSIC_LOGGING` | Collect evidence before destroy | `"true"` | `"false"` | `false` = no post-incident analysis | Recommended true |
| `RECOVERY_PROCEDURES` | Auto-launch clean child after destroy | `"true"` | `"false"` | `false` = manual recovery needed | Recommended true |

### Update Settings

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `AUTO_UPDATE_MAINSTREAM` | Auto-update host kernel packages | `"false"` | `"true"` | `true` may reboot at inconvenient times | None |
| `AUTO_UPDATE_MULTIKERNEL` | Auto-update multikernel from source | `"false"` | `"true"` | `true` may introduce untested builds | None |
| `AUTO_SYNC_CHILD` | Auto-sync child kernel after updates | `"false"` | `"true"` | `true` may sync broken builds to child | None |

### Cross-Distro Settings

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `CROSS_DISTRO_ENABLE` | Allow non-Arch child distributions | `"false"` | `"true"` | Requires debootstrap or dnf installed | None |
| `CHILD_DISTRO` | Which distro for child rootfs | `"debian"` | `ubuntu`, `fedora`, `rhel` | Missing tool for chosen distro | None |

### Btrfs Snapshot Settings

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `BTRFS_SNAPSHOT_ENABLE` | Auto-snapshot before changes | `"false"` | `"true"` (requires btrfs) | No btrfs = snapshots fail silently | None |
| `BTRFS_SNAPSHOT_KEEP` | Number of snapshots to retain | `"5"` | Any positive integer | 0 = no retention | None |

### Installation Target

| Key | Controls | Default | Safe Alternatives | Breaks If | Compliance Impact |
|-----|----------|---------|-------------------|-----------|-------------------|
| `INSTALL_TARGET` | Where to install child kernel | `"secondary-disk"` | `sd-card`, `host-partition` | `host-partition` weakens isolation | `host-partition` reduces compliance |

---

## 5. Hardware Constraints and Requirements

These are hard requirements. Violating any of these will cause scripts to fail or, worse, silently produce a non-compliant deployment.

### CPU

- **Architecture:** x86_64 only. `2_setup.sh` checks `uname -m` and exits if not x86_64.
- **IOMMU:** Must support Intel VT-d or AMD-Vi. Without IOMMU, there's no hardware boundary between host and child.
- **Cores:** 8+ recommended. `CHILD_CPU_MASK` (default `0xFFFFFFF0`) gives the child every CPU except 0-3; extra mask bits beyond the physical CPU count are ignored via the nproc cap.

### RAM

- **Minimum:** 8GB total. `2_setup.sh` exits below this.
- **Recommended:** 128GB (reference build). The reference split is `movablecore=116G`: child pool 81917M inside ZONE_MOVABLE; the ~36GB of slack the pool does not claim returns to the host after the baseline.
- **Child allocation:** Config-driven via `CHILD_MEMORY_SIZE` — every DT block (spawn, auto-destroy, recovery) computes its `size` cell from it via `scripts/lib-hardware.sh`. There is no hardcoded memory value anywhere.
- **Reservation:** `movablecore=` in the host cmdline is mandatory; `spawn-child-instance.sh` aborts without it (override: `MEMORY_RESERVATION_ACKNOWLEDGED="true"`). The first spawn applies the baseline that converts the zone into the pool.

### Disk

- **Count:** Minimum 2 physical disks. `2_setup.sh` counts disks matching `sd|vd|nvme` and requires at least 2.
- **Child disk size:** 25GB+ (512MB boot + 20GB root + data). `sd-card-2_setup.sh` uses the same layout.
- **Host disk:** Untouched by all scripts. `partition-disk.sh` explicitly excludes the root device.

### Boot

- **systemd-boot:** Required for the reference setup. Boot entries live in `/boot/loader/entries/`.
- **GRUB:** Supported as an alternative. The test checklist includes GRUB kernel parameter instructions.
- **Secure Boot:** Must be disabled, or modules must be signed with MOK. `test-checklist.md` provides `mokutil --sb-state` check.

### BIOS/UEFI

- **IOMMU:** Must be enabled. Called "VT-d" on Intel, "AMD-Vi" on AMD. Usually found under Advanced or Northbridge settings.
- **Virtualization:** SVM (AMD) or VT-x (Intel) should be enabled.

### Kernel Parameters

Add these to your bootloader entry:

```
intel_iommu=on iommu=pt
```

or

```
amd_iommu=on iommu=pt
```

For systemd-boot, edit the appropriate file in `/boot/loader/entries/`.
For GRUB, edit `/etc/default/grub` and run `grub-mkconfig`.

Verify with: `dmesg | grep -i iommu`

### Kernel Config

The multikernel kernel must be built with:

```
CONFIG_MULTIKERNEL=y
CONFIG_OF=y
```

Verify with: `zcat /proc/config.gz | grep MULTIKERNEL`

---

## 6. SUSPICIOUS Framework Compliance Checklist

### Must Remain Unchanged (Full Compliance)

These are non-negotiable. Changing any of these breaks the security model.

- [ ] `MODULE_SIGNING_ENFORCE="true"` - Unsigned modules are a rootkit vector
- [ ] `IOMMU_VERIFY="true"` - Hardware boundary is the foundation of isolation
- [ ] `CAPABILITY_DROPPING="true"` - Child must run with zero elevated privileges
- [ ] `FILESYSTEM_ISOLATION="true"` - Read-only root prevents persistent tampering
- [ ] `NETWORK_ISOLATION="true"` - No network access prevents data exfiltration
- [ ] `AUTO_DESTROY_ON_DETECTION="true"` - Compromised child must not continue running
- [ ] Separate physical disks for host and child
- [ ] IOMMU enabled in BIOS and kernel parameters
- [ ] `CONFIG_MULTIKERNEL=y` in kernel build
- [ ] Child kernel has no route to host disk
- [ ] systemd as init system

### Can Be Customized Without Breaking Compliance

These are user preferences that don't affect the security model.

- [ ] Filesystem type (ext4, btrfs, xfs, f2fs, zfs)
- [ ] Partition sizes (boot, root, data)
- [ ] Security level preset (basic, intermediate, advanced)
- [ ] Cross-distro support and distro choice
- [ ] Btrfs snapshot automation and retention
- [ ] Auto-update toggles
- [ ] Detection monitor toggles (they add coverage but aren't the enforcement mechanism)
- [ ] Bootloader choice (systemd-boot or GRUB)
- [ ] Specific disk device paths
- [ ] Install target (secondary-disk or sd-card)

### How to Verify Compliance After Customization

```bash
# 1. Run the security audit
sudo ./scripts/security-audit.sh

# 2. Verify IOMMU is active
sudo ./prevention/verify-iommu.sh

# 3. Check kernel config
zcat /proc/config.gz | grep MULTIKERNEL

# 4. Verify multikernel sysfs is mounted
ls /sys/fs/multikernel/instances/

# 5. Check IOMMU kernel parameter
cat /proc/cmdline | grep iommu

# 6. Verify network isolation in child
# (from within child) ping 8.8.8.8  # Should fail

# 7. Run the full test checklist
# See docs/test-checklist.md, Phase 14: Security Verification
```

---

## 7. Troubleshooting by Hardware Configuration

### IOMMU Not Detected

**Symptoms:** `verify-iommu.sh` fails. `dmesg | grep -i iommu` returns nothing. `/sys/kernel/iommu_groups/` doesn't exist.

**Diagnosis:**
```bash
# Check BIOS setting
dmesg | grep -i "DMAR\|AMD-Vi"

# Check kernel parameter
cat /proc/cmdline | grep iommu
```

**Fix:** Enable VT-d or AMD-Vi in BIOS/UEFI. Add `intel_iommu=on` or `amd_iommu=on` to kernel parameters. Reboot.

### Second Disk Not Found

**Symptoms:** `2_setup.sh` reports "Secondary disks: None found". `partition-disk.sh` exits with "No secondary disk found".

**Diagnosis:**
```bash
# List all block devices
lsblk -d

# Check if disk is connected
ls /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null
```

**Fix:** Verify physical connection. Check BIOS/UEFI disk detection. If using USB-attached disk, it may appear as `/dev/sdX` but some scripts filter for non-removable devices. For SD cards, use `sd-card-2_setup.sh` which specifically looks for removable storage.

### SD Card Too Slow

**Symptoms:** `sd-card-2_setup.sh` warns about UHS support. Child kernel boots slowly or times out.

**Diagnosis:** The script checks `/sys/block/DEVICE/device/cid` for UHS class.

**Fix:** Use UHS-I or faster (100MB/s+). Class 10 minimum. SD card testing is meant for evaluation, not production.

### Insufficient RAM

**Symptoms:** `2_setup.sh` errors with "Available memory: XGB (minimum: 8GB required)".

**Diagnosis:** `free -g` shows total RAM.

**Fix:** The host needs enough RAM for itself plus VMs (~45GB available in the reference split after the baseline). Reduce the child allocation by setting `CHILD_MEMORY_SIZE` in the config — every DT block follows it automatically — and keep `movablecore` at least CHILD_MEMORY_SIZE + scan slack (~36GB reference): e.g. `movablecore=52G` with `CHILD_MEMORY_SIZE="16G"` gives a small child and a large host.

### systemd-boot Entry Not Found

**Symptoms:** Can't find boot entry to add IOMMU parameters.

**Diagnosis:**
```bash
# List all boot entries
ls /boot/loader/entries/

# Check which entry is default
bootctl status
```

**Fix:** Look for the entry containing `multikernel` in the filename or title. If using GRUB instead, edit `/etc/default/grub` and run `sudo grub-mkconfig -o /boot/grub/grub.cfg`.

### Secure Boot Blocking Modules

**Symptoms:** Multikernel modules fail to load. `dmesg` shows "module verification failed" or similar.

**Diagnosis:**
```bash
mokutil --sb-state
```

**Fix:** Either disable Secure Boot in BIOS/UEFI, or sign the multikernel modules with a Machine Owner Key (MOK). The test checklist has detailed instructions.

### Cross-Distro Rootfs Creation Fails

**Symptoms:** `install-child-kernel.sh` fails during `debootstrap` or `dnf` phase.

**Diagnosis:**
```bash
# Check debootstrap
debootstrap --version

# Check dnf
dnf --version

# Test internet connectivity
ping -c 1 deb.debian.org
```

**Fix:** Install the required tool (`pacman -S debootstrap` or `pacman -S dnf`). Verify internet access. Check that the target mirror is reachable.

### Filesystem-Specific Issues

**btrfs:** Snapshots fail if `btrfs-progs` isn't installed. Subvolume must be on a btrfs partition.

**zfs:** Requires `zfs-utils` package. ZFS kernel module must be loaded. Only available at advanced security level.

**xfs:** No `e2fsck` equivalent. `setup-filesystem-isolation.sh` skips the filesystem check when xfs is used (e2fsck is ext4-only).

**f2fs:** Requires `f2fs-tools`. Flash-optimized, so best for SD cards and SSDs.

### Child Kernel Won't Boot

**Symptoms:** Boot entry exists but child kernel doesn't start.

**Diagnosis:**
```bash
# Check multikernel sysfs
ls /sys/fs/multikernel/instances/

# Check kernel logs
dmesg | grep -i multikernel

# Verify kernel files exist on child boot partition
sudo mount /dev/sdb1 /mnt
ls /mnt/
sudo umount /mnt
```

**Fix:** Run `sync-child-kernel.sh` to ensure kernel files are current. Verify the boot entry points to the correct kernel image and initramfs. Check that `multikernel.role=child` is in the kernel command line.

---

## Related Documentation

- [README.md](../README.md) - Project overview and quick start
- [docs/test-checklist.md](test-checklist.md) - Complete testing procedures
- [docs/filesystem-guide.md](filesystem-guide.md) - Filesystem comparison and recommendations
- [docs/cross-distro-guide.md](cross-distro-guide.md) - Cross-distro child instance setup


---

## Adapting to Your Machine

Every customization follows the same triad — **key → file → verification**:

| You want to change | Edit | Verify after |
|--------------------|------|--------------|
| Child RAM reservation | `CHILD_MEMORY_SIZE` in `etc/proj-mk-ultra.conf` + matching `movablecore=` boot param + baseline | `grep -A8 'zone.*Movable' /proc/zoneinfo \| grep present` + `sudo dmesg \| grep 'Multikernel pool: added'` + `free -g` |
| Target disk | `TARGET_DISK` (bare name, e.g. `sdb`) | `lsblk` — device exists, is NOT your root disk |
| CPUs the child owns | `CHILD_CPU_MASK` (hex; host keeps 0-3 by default) | `nproc` + popcount of mask; DT `cpu-mask` in spawn output |
| Display handoff | `PASSTHROUGH_PCI_DEVICES` += your GPU slot (`lspci -nn`) | spawn output shows "Released <driver> from <slot>" |
| Child root size | `CHILD_ROOT_SIZE` | `partition-disk.sh` planned layout before YES |
| Filesystem diversity | `CHILD_LEAPFROG_FS_ENABLE="true"` + `CHILD_LEAPFROG_FS` | wizard intermediate+; `lsblk -f` after partitioning shows different FS |
| Auto-updates | `AUTO_UPDATE_*` flags | `update-*.sh` print "disabled by config" and exit 0 |
| Kernel pin | `PINNED_COMMIT` in `pre-install/build-multikernel.sh` + `docs/BUILD-MULTIKERNEL.md` | `git -C /opt/multikernel/linux rev-parse --short HEAD` matches |

Full key reference: the tables above. Full deployment flow: docs/DEPLOYMENT-GUIDE.md.
