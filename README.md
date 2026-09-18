# PROJ-MK-ULTRA

## Sovereign Agentic Computing Isolation Platform

**Version:** 1.0.0  
**Status:** Production Release  
**License:** AGPLv3

---

## What Is This?

PROJ-MK-ULTRA is a complete, production-ready deployment of the **SUSPICIOUS Framework** for sovereign agentic computing isolation. It provides:

- **Kernel-level isolation** via Multikernel Linux
- **Hardware-level protection** via IOMMU/VFIO
- **Ephemeral child kernels** that self-destruct on anomaly detection
- **User data preservation** across kernel rebuilds
- **Automatic recovery** from detected attacks

This is not a toy. This is the real thing. 

**IT IS HOWEVER -> INCOMPLETE**. 

I haven't been able to get it to launch into a child-kernel instance for true "kernel-level-isolation" _yet_. 

Now is as good of a time as any, to start building in public I'd suppose...

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/loudmumble/proj-mk-ultra.git
cd proj-mk-ultra

# Run the setup wizard
sudo ./2_setup.sh
```

The wizard will guide you through:
1. System detection and compatibility check
2. Configuration (filesystem, security level, hardware assignment)
3. Pre-installation verification (memory reservation, sysfs, partitioning, child rootfs)
4. Prevention layer configuration
5. Detection layer setup
6. Response layer configuration
7. Update system setup
8. Final verification and summary

---

## Deployment (The Complete Sequence)

**Read [docs/DEPLOYMENT-GUIDE.md](docs/DEPLOYMENT-GUIDE.md) first** — it is
the complete universal walkthrough, written for users of any background,
with every real-world failure and its fix. The compressed sequence:

```
1. BIOS/UEFI     Enable VT-d/AMD-Vi + VT-x/SVM; leave Secure Boot as-is
2. HOST KERNEL   Multikernel Linux v7.0-mk2 built from multikernel/linux
3. BOOT PARAMS   intel_iommu=on iommu=pt movablecore=116G nouveau.config=NvGpuRm=1
                 (NEVER vfio-pci.ids= on the host — passthrough happens at spawn)
4. INITRAMFS     MODULES=(vfio vfio_iommu_type1 vfio_pci) + mkinitcpio -P
                 + multikernel initrd: mkinitcpio -g <FULL initrd path>
                 → validate BOTH images BEFORE the reboot
5. HOST VM       Shut down, set allocation ≤ ~8GB (virt-manager: cold change)
6. REBOOT        ONE reboot activates params + initramfs + memory carve
7. VERIFY        grep -A8 'zone.*Movable' /proc/zoneinfo | grep present; free -g (~45GB available post-baseline);
                 uname -r (mk2); cat /proc/sys/kernel/tainted (0)
8. TRANSFER      Copy the LATEST repo state to the host (a stale copy misses
                 current preflights/docs); insert SD card, confirm /dev/sdb
9. SETUP         sudo ./2_setup.sh (wizard; config pre-filled in etc/)
10. SPAWN        mount -t multikernel none /sys/fs/multikernel
                 spawn-child-instance.sh --check   (preflight)
                 suspicious-boot.sh option 1       (real spawn)
11. VERIFY       host taint=0 forever; child taint=12288 dies with the child
```

**Host requirements:** x86_64, IOMMU-capable CPU, 2+ disks (SD card accepted),
systemd init. The memory reservation (`movablecore=116G` on the 128GB reference
build: the top 116GB enters ZONE_MOVABLE; the baseline claims `CHILD_MEMORY_SIZE`
(81917M reference) of it as the child pool, and the unused ~36G returns to the host
after the baseline) is **mandatory** —
memory has no IOMMU equivalent, and the spawn preflight refuses to run
without it. See DEPLOYMENT-GUIDE.md section 7 for the reasoning and the math.

---

## Documentation Index

| Document | Contents |
|----------|----------|
| [docs/DEPLOYMENT-GUIDE.md](docs/DEPLOYMENT-GUIDE.md) | **Start here.** Zero-to-child walkthrough, Windows-user primer, BIOS/kernel-params/movablecore, spawn flow, invariant verification, full troubleshooting table, SUSPICIOUS framework mapping |
| [docs/BUILD-MULTIKERNEL.md](docs/BUILD-MULTIKERNEL.md) | Kernel build: pinned commit, config fragment, per-distro package tables (Arch/Debian-Kali/Fedora), boot entry, module-signing trust chain |
| [docs/BUILD-CUSTOMIZATION.md](docs/BUILD-CUSTOMIZATION.md) | Every config key (42 keys), hardware design considerations, memory sequestration deep-dive |
| [docs/test-checklist.md](docs/test-checklist.md) | 15 test phases from syntax validation to security verification, with per-phase prerequisites |
| [docs/filesystem-guide.md](docs/filesystem-guide.md) | Leapfrog filesystem diversity mechanics |
| [docs/cross-distro-guide.md](docs/cross-distro-guide.md) | Debian/Fedora child instances |
| `useful-scripts/kernel-pin.sh` | Kernel pin manager (get/set/verify) — one command to re-pin or confirm the clone matches |
| `useful-scripts/generate-config.sh` | **Hardware-to-config generator**: detects RAM/CPUs/disks/GPU/USB/NIC/distro and generates `etc/proj-mk-ultra.conf` (dry-run default; `--write` backs up + installs) |

---

## Security Levels

### Basic
- Same filesystem for all partitions
- No leapfrog, no cross-distro
- Simplest configuration

### Intermediate
- Leapfrog filesystem diversity enabled
- User selects filesystems for each generation
- Good balance of security and complexity

### Advanced
- Leapfrog enabled
- User selects filesystems for each generation
- Cross-distro optional (recommended for maximum isolation)
- btrfs snapshots optional (if using btrfs)
- Maximum isolation

---

## Filesystem Diversity (Leapfrog)

Using different filesystems between host and child kernels makes poisoned metadata payloads incompatible across boundaries.

```
Host: ext4 (on /dev/sda)
Child: btrfs (on /dev/sdb2)
Grandchild: xfs (on /dev/sdb2)
```

See [docs/filesystem-guide.md](docs/filesystem-guide.md) for details.

---

## Testing

See [docs/test-checklist.md](docs/test-checklist.md) for comprehensive testing procedures.

### Quick Test Commands

```bash
# Syntax validation (can run on any system)
find . -name "*.sh" -type f -exec bash -n {} \;

# Configuration test
sudo ./scripts/load-config.sh

# Security audit
sudo ./scripts/security-audit.sh

# System monitor
sudo ./scripts/system-monitor.sh
```

---

## Cross-Distro Support

Boot different Linux distributions as child instances using the same multikernel kernel:

- Debian/Ubuntu (via debootstrap)
- Fedora/RHEL (via dnf)

See [docs/cross-distro-guide.md](docs/cross-distro-guide.md) for details.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HOST KERNEL (Sovereign)                             │
│                     Multikernel Linux v7.0-mk2                              │
│                     tainted = 0 (nouveau only, NEVER modified)              │
│                     Disk: /dev/sda (host OS)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PREVENTION LAYER (Host)                           │   │
│  │  ✓ IOMMU verification (intel_iommu=on / amd_iommu=on)             │   │
│  │  ✓ Module signing enforcement (host kernel only)                    │   │
│  │  ✓ Capability dropping (PrivateUsers=pick, Capability=none)        │   │
│  │  ✓ Filesystem isolation (ReadOnly=yes, Volatile=yes)               │   │
│  │  ✓ Network isolation (PrivateNetwork=yes)                          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    DETECTION LAYER (Host)                            │   │
│  │  ✓ Boot integrity monitoring (/proc/sys/kernel/tainted == 0)       │   │
│  │  ✓ Hardware isolation monitoring (IOMMU groups)                     │   │
│  │  ✓ Sysfs access monitoring (/sys/fs/multikernel)                    │   │
│  │  ✓ Module loading monitoring (unsigned module detection)            │   │
│  │  ✓ Behavioral anomaly detection                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    RESPONSE LAYER (Host)                             │   │
│  │  ✓ Auto-destroy child on detection                                  │   │
│  │  ✓ Data preservation (/dev/sdb3 survives child rebuild)            │   │
│  │  ✓ Forensic logging (/opt/suspicious/forensic/)                     │   │
│  │  ✓ Recovery procedures                                             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    UPDATE SYSTEM (Host)                              │   │
│  │  ✓ Mainstream kernel updates (dnf/pacman/apt)                      │   │
│  │  ✓ Multikernel updates (git pull from GitHub)                       │   │
│  │  ✓ Child kernel sync (rsync to /dev/sdb)                            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│               CHILD KERNEL (Ephemeral — Born, Works, Dies)                  │
│               tainted = 12288 when NVIDIA loaded (temporary)                │
│               Disk: /dev/sdb (child disk)                                   │
│               DESTROYED on anomaly → REBORN fresh                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  /dev/sdb1 - Boot (FAT32, 512MB)                                           │
│  /dev/sdb2 - Root (ext4, 20GB) — EPHEMERAL, destroyed on anomaly           │
│  /dev/sdb3 - User Data (ext4, 100% of remaining) — PERSISTS across rebuilds        │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  CHILD KERNEL OPERATIONS:                                            │   │
│  │  ✓ nvidia-open-dkms loaded HERE (tainted=12288)                     │   │
│  │  ✓ llama-server (llama.cpp) runs HERE for local inference          │   │
│  │  ✓ libvirt/QEMU VM launched HERE                                    │   │
│  │    └─► Kali Linux VM with repo disk attached                        │   │
│  │        (or pulled from RPI via Python text server)                   │   │
│  │  ✓ Child is ephemeral — NVIDIA taint dies with it                   │   │
│  │  ✓ Host never sees NVIDIA, never gets tainted                       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  MULTI-INSTANCE SUPPORT:                                             │   │
│  │  ✓ Child kernels can spawn additional child instances                │   │
│  │  ✓ Each instance runs in isolated memory space                       │   │
│  │  ✓ Shared /data partition for persistent user files                  │   │
│  │  ✓ Spawn from within child kernel                                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

ISOLATION BOUNDARIES:
─────────────────────
• Host data (/dev/sda) ←→ Child data (/dev/sdb3): PHYSICALLY SEPARATE DISKS
• Host kernel (tainted=0) ←→ Child kernel (tainted=12288): HARDWARE ISOLATION (IOMMU/VFIO)
• Host memory (~45GB after pool) ←→ Child memory (81917M): BOOT-TIME ZONE_RESERVATION (movablecore=116G) + baseline pool
  - Peripherals are isolated by the IOMMU; memory has no IOMMU equivalent
  - The host allocator must NEVER own the child's frames → carved at boot, verified by spawn preflight
• Host NEVER loads NVIDIA → Host NEVER tainted
• Child loads NVIDIA → Child tainted (12288) → Child destroyed → Taint disappears
• Child root (/dev/sdb2): EPHEMERAL — destroyed on anomaly detection
• User data (/dev/sdb3): PERSISTS — survives child kernel rebuild
• Host CAN mount /dev/sdb3 for backup/restore — this is by design
• Child CANNOT access host disk (/dev/sda) — hardware boundary

NVIDIA / GPU ARCHITECTURE:
──────────────────────────
• Host: nouveau only, tainted=0, display output works
• Child: nvidia-open-dkms loaded, tainted=12288 (temporary)
• Child: llama-server uses GPU for inference via CUDA
• Child: libvirt/QEMU VM can use GPU passthrough (VFIO)
• When child is destroyed, NVIDIA taint dies with it
• Host remains pristine across all child lifecycle events

SECURITY INVARIANT:
───────────────────
• /proc/sys/kernel/tainted on HOST must ALWAYS return 0
• If it returns non-zero, something touched the host → ANOMALY → DESTROY CHILD
• Child taint is expected and acceptable (ephemeral by design)
• Host taint is NEVER acceptable (sovereign by design)
```

---

## Directory Structure

```
proj-mk-ultra/
├── 1_pre-install.sh                   # Fresh-machine kernel build + boot entry + conf bootstrap
├── 2_setup.sh                         # Main installation wizard
├── README.md                          # This file
├── pre-install/                       # Pre-installation checks
│   ├── check-multikernel.sh           # Verify multikernel support
│   ├── check-disks.sh                 # Check disk configuration
│   ├── partition-disk.sh              # Partition secondary disk
│   ├── install-child-kernel.sh        # Install child kernel + rootfs
│   ├── build-multikernel.sh           # Kernel build (fragment merge, fork patches)
│   └── setup-updates.sh               # Configure update system
├── prevention/                        # Prevention layer
│   ├── verify-iommu.sh                # Verify IOMMU configuration
│   ├── enforce-module-signing.sh      # Enforce module signing
│   ├── enroll-mok.sh                  # Secure Boot MOK enrollment
│   ├── setup-capability-dropping.sh   # Configure capability dropping
│   ├── setup-filesystem-isolation.sh  # Configure filesystem isolation
│   └── setup-network-isolation.sh     # Configure network isolation
├── detection/                         # Detection layer
│   ├── resident-watch.sh              # Continuous watcher (suspicious-watch.service)
│   ├── suspicious-watch.service       # Watcher systemd unit
│   ├── monitor-boot-integrity.sh      # Monitor boot integrity
│   ├── monitor-hardware-isolation.sh  # Monitor hardware isolation
│   ├── monitor-sysfs-access.sh        # Monitor sysfs access
│   ├── monitor-module-loading.sh      # Monitor module loading
│   └── monitor-behavioral-anomalies.sh # Detect behavioral anomalies
├── response/                          # Response layer
│   ├── auto-destroy.sh                # Auto-destroy on detection
│   ├── preserve-data.sh               # Preserve user data
│   ├── forensic-logging.sh            # Forensic logging
│   └── recovery.sh                    # Recovery procedures
├── update/                            # Update system
│   ├── update-mainstream.sh           # Update mainstream kernel
│   ├── update-multikernel.sh          # Update multikernel (re-applies fork patches)
│   └── sync-child-kernel.sh           # Sync child kernel
├── scripts/                           # Deployment & runtime scripts
│   ├── apply-baseline.sh              # Boot-time pool baseline (mk-baseline.service)
│   ├── spawn-child-instance.sh        # Spawn child instances
│   ├── boot-instance.sh               # Boot/stop child instances
│   ├── launch-cycle.sh                # One-command baseline → spawn → boot → FSV
│   ├── first-spawn-validate.sh        # FSV-1..5 automated validation
│   ├── probe-pool-ceiling.sh          # Find the machine's pool ceiling
│   ├── lib-hardware.sh                # Shared hardware-assignment helpers
│   ├── suspicious-boot.sh             # Boot selector
│   ├── security-audit.sh              # Run security audit
│   ├── system-monitor.sh              # Monitor system
│   ├── btrfs-snapshot.sh              # Btrfs snapshot management
│   ├── sd-card-setup.sh               # SD card testing setup
│   ├── complete-uninstall.sh          # Complete uninstall
│   ├── create-debian-rootfs.sh        # Create Debian rootfs (cross-distro)
│   ├── create-rpm-rootfs.sh           # Create Fedora/RHEL rootfs (cross-distro)
│   ├── load-config.sh                 # Load configuration
│   └── save-config.sh                 # Save configuration
├── useful-scripts/                    # Research & maintenance tools
│   ├── generate-config.sh             # Hardware-detected conf generator
│   ├── kernel-pin.sh                  # Kernel commit pinning helper
│   ├── multi-kernel-update.sh         # Complete kernel update manager
│   ├── kernel-manager.sh              # Multikernel instance manager
│   ├── metadata-cleaner.sh            # RPI metadata poisoning cleanup
│   ├── structural-analyzer.sh         # Code structure analysis
│   ├── git-protect.sh                 # Git repository protection
│   ├── git-remediate.sh               # Git repository remediation
│   └── system-monitor.sh              # System resource monitoring
├── systemd/                           # systemd unit templates
│   └── mk-baseline.service            # Boot-time baseline unit (paths set at install)
├── etc/                               # Configuration
│   ├── proj-mk-ultra.conf             # Live configuration
│   ├── proj-mk-ultra.conf.example     # Template with documented defaults
│   └── *.dts                          # Labeled DTB reference examples
├── patches/                           # Required fork patches
│   └── 0001-mk-ctrl-pgtable-pages-256.patch  # MK_CTRL_PGTABLE_PAGES 64→256
├── config/                            # Kernel config fragment
│   └── multikernel-proj-mk-ultra.fragment
└── docs/                              # Documentation
    ├── filesystem-guide.md           # Filesystem comparison
    └── cross-distro-guide.md         # Cross-distro support
```

---

## Security Model

### CBPI (Compositional Boundary Precedence Inversion) Prevention

The SUSPICIOUS Framework prevents CBPI attacks by:

1. **Namespace Isolation**: Child kernel runs in separate UID space
2. **Capability Dropping**: No elevated privileges available
3. **Seccomp Filtering**: Restricted syscall set
4. **Network Segmentation**: No network access
5. **Filesystem Isolation**: Read-only root filesystem

### Mathematical Invariants

1. **Identity Invariant**: `UID 1000 = UID 1000`
   - Agent runs under different UID than host
   - No identity collision possible

2. **Trust Boundary**: Single-master local runtime
   - No cloud pre-prompts (β = 0)
   - User controls all model parameters
   - Transparent, mutable system prompts

3. **Isolation Properties**:
   - PrivateUsers=pick (namespace isolation)
   - Capability=none (no elevated privileges)
   - PrivateNetwork=yes (no network access)
   - ReadOnly=yes (immutable root filesystem)

### Kernel Taint Invariant (NVIDIA Architecture)

The host kernel MUST maintain `tainted = 0` at all times. This is the definitive anomaly signal.

```
Host kernel:   tainted = 0      (nouveau only, NEVER loads proprietary modules)
Child kernel:  tainted = 12288  when NVIDIA loaded (ephemeral, dies on rebuild)
```

**NVIDIA taint value breakdown (12288):**
- Bit 12 (O = 4096): out-of-tree module loaded (NVIDIA not in kernel source tree)
- Bit 13 (E = 8192): unsigned module loaded (signature verification failed)
- Total: 4096 + 8192 = 12288

**Why this works:**
- Host uses nouveau (open-source) for display output — no proprietary modules
- Child loads `nvidia-open-dkms` (open-source kernel module, GPL-compatible) for CUDA/llama-server — taints child to 12288
- Because nvidia-open-dkms is GPL-compatible, bit 0 (proprietary) is NOT set — only bits 12+13 (out-of-tree + unsigned)
- Child is ephemeral: destroyed on anomaly → rebuilt fresh → taint disappears
- Host never loads NVIDIA → host never tainted → `/proc/sys/kernel/tainted` stays `0`
- Detection layer monitors HOST taint only, not child taint

**Security guarantee:**
- If host `tainted != 0`: something touched the host → ANOMALY → destroy child immediately
- If child `tainted = 12288`: expected (NVIDIA loaded) → continue operating
- Child taint is born and dies with each instance lifecycle

**GPU workload architecture:**
```
Host (tainted=0, nouveau)
  └─► Child kernel (ephemeral, NVIDIA, tainted=12288)
        ├─► llama-server (llama.cpp) — local inference via CUDA
        └─► libvirt/QEMU VM — Kali Linux with repo disk
              └─► Actual development work happens here
```

**RPI → Child data flow (metadata poisoning prevention):**
```
RPI (untrusted source)
  → Python text server (launch-bulk-text-server.py)
    → Strips xattr, symlinks, ACLs, re-timestamps
      → Child kernel receives clean file contents only
        → VM inside child gets the repo
```

---

## Usage

### Daily Workflow

```bash
# 1. Start your day - run the boot selector
sudo ./scripts/suspicious-boot.sh

# 2. Select option 1 to launch agent instance
#    (Choose CPU cores and memory allocation)

# 3. Work with the agent in the isolated kernel
#    The agent runs in a completely separate kernel

# 4. When done, stop the agent instance
#    (Option 2 in the boot selector)

# 5. Run security audit periodically
sudo ./scripts/security-audit.sh
```

### Commands

```bash
# Run security audit
sudo ./scripts/security-audit.sh

# Monitor system
sudo ./scripts/system-monitor.sh

# Boot selector
sudo ./scripts/suspicious-boot.sh

# Btrfs snapshot management (if using btrfs)
sudo ./scripts/btrfs-snapshot.sh create [name]
sudo ./scripts/btrfs-snapshot.sh list
sudo ./scripts/btrfs-snapshot.sh rollback [name]

# SD card testing setup
sudo ./scripts/sd-card-setup.sh

# Complete uninstall (host pristine preservation)
sudo ./scripts/complete-uninstall.sh

# Update system
sudo ./update/update-mainstream.sh
sudo ./update/update-multikernel.sh
sudo ./update/sync-child-kernel.sh

# Useful scripts
sudo ./useful-scripts/multi-kernel-update.sh update    # Update all kernel components
sudo ./useful-scripts/multi-kernel-update.sh status     # Show current kernel info
sudo ./useful-scripts/multi-kernel-update.sh rollback   # Rollback to previous kernel
sudo ./useful-scripts/kernel-manager.sh list            # List kernel instances
sudo ./useful-scripts/kernel-manager.sh monitor         # Real-time monitoring
```

---

## Requirements

### Hardware

- **Architecture**: x86_64 only
- **CPU**: Multicore processor (recommended: 8+ cores)
- **Memory**: 16GB+ RAM (minimum: 8GB)
- **Storage**: 2 disks (host + child)
- **IOMMU**: Supported and enabled

### Software

- **Kernel**: Multikernel Linux v7.0-mk2
- **Init**: systemd
- **Bootloader**: GRUB or systemd-boot
- **Host OS**: Arch Linux (primary), Debian/Ubuntu, Fedora/RHEL

### Cross-Distro Requirements (if enabled)

- **debootstrap**: For Debian/Ubuntu child instances
- **dnf**: For Fedora/RHEL child instances
- **Internet connection**: For package download during rootfs creation

### Distro Support

- Arch Linux (primary)
- Debian/Ubuntu
- Fedora/RHEL/CentOS
- Generic (tarball)

---

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| "Multikernel filesystem not mounted" | `sudo mount -t multikernel none /sys/fs/multikernel` |
| "Agent instance fails to boot" | Check `dmesg \| grep multikernel` for errors |
| "Permission denied" | Run with `sudo` |
| "IOMMU not enabled" | Enable in BIOS/UEFI and add `intel_iommu=on` to kernel parameters |
| "Secondary disk not found" | Check `lsblk` and ensure disk is connected |
| "Btrfs snapshot fails" | Ensure btrfs-progs is installed: `sudo pacman -S btrfs-progs` |
| "ZFS not available" | Install ZFS: `sudo pacman -S zfs-utils` |
| "Cross-distro rootfs creation fails" | Check internet connection and debootstrap/dnf installation |
| "SD card not detected" | Ensure card is inserted and device is not mounted |
| "Configuration not found" | Run `sudo ./scripts/load-config.sh` to initialize |

### Getting Help

```bash
# Check multikernel status
ls /sys/fs/multikernel/instances/

# View kernel logs
dmesg | grep -i multikernel

# Check systemd-nspawn
systemd-nspawn --help

# Verify kernel config
zcat /proc/config.gz | grep MULTIKERNEL
```

---

## References

### Primary Sources

1. **Multikernel Linux**
   - Repository: https://github.com/multikernel/linux
   - Announcement: https://lore.kernel.org/lkml/2026/08/25/1911

2. **SUSPICIOUS Framework (CBPI Research)**
   - Repository: https://github.com/loudmumble/cbpi-sus-pub
   - Thesis: `documents/Thesis_SUSPICIOUS_Complete.md`

### Key Concepts

- **CBPI**: Compositional Boundary Precedence Inversion
- **DMAP**: Dual-Master Agentic Paradox
- **SUSPICIOUS**: Sovereign User-System Protocol for Instantiated Computational Interface and Operational User Standards

---

## Contributing

This is a production release. Contributions welcome:

1. Test on different hardware configurations
2. Add support for additional architectures
3. Improve the boot selector interface
4. Enhance security audit coverage
5. Document additional use cases

---

## License

- **Scripts**: AGPLv3
- **Documentation**: CC-BY-NC-ND-4.0

---

## Acknowledgments

- **loudmumble**: Creator of the SUSPICIOUS Framework and CBPI research
- **Multikernel Technologies**: Multikernel Linux implementation
- **Arch Linux Community**: Distribution and packaging

---

*This software is provided as-is for educational purposes. Always verify security configurations meet your specific requirements.*
