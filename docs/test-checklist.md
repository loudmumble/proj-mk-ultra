# PROJ-MK-ULTRA Test Checklist

## Pre-Test Requirements

### Host System Prerequisites (CRITICAL - Must Complete Before Any Testing)

#### BIOS/UEFI Configuration
- [ ] IOMMU enabled in BIOS/UEFI (Intel VT-d or AMD-Vi)
- [ ] SVM/VT-x enabled

#### Secure Boot Status (Check First)
```bash
# Check Secure Boot status
mokutil --sb-state 2>/dev/null || echo "mokutil not available"
cat /sys/kernel/security/secureboot/enabled 2>/dev/null || echo "Cannot read secureboot status"
```
- [ ] Secure Boot status determined
- [ ] If ENABLED: Either disable in BIOS/UEFI, OR sign multikernel modules with MOK
- [ ] If DISABLED: Proceed with installation

#### Kernel Boot Parameters
- [ ] `intel_iommu=on` or `amd_iommu=on` added to kernel command line
- [ ] `iommu=pt` (passthrough) recommended

**For systemd-boot (Arch Linux):**
```bash
# Find your multikernel entry
ls /boot/loader/entries/*multikernel* 2>/dev/null

# Add IOMMU parameter to the entry
sudo sed -i 's/^options /options intel_iommu=on /' /boot/loader/entries/YOUR-ENTRY.conf

# Verify
grep "^options" /boot/loader/entries/YOUR-ENTRY.conf
```

**For GRUB:**
```bash
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on /' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

- [ ] Reboot after adding IOMMU parameter
- [ ] Verify IOMMU active: `dmesg | grep -i iommu`

#### Driver Loading
- [ ] VFIO driver loaded: `sudo modprobe vfio-pci`
- [ ] VFIO persists across reboot: `echo "vfio-pci" | sudo tee /etc/modules-load.d/vfio-pci.conf`

#### System Requirements
- [ ] systemd as init system: `pidof systemd`
- [ ] Internet connection available (for package downloads)
- [ ] sudo access configured

### Hardware Verification
- [ ] x86_64 architecture confirmed
- [ ] 8+ CPU cores available (4 for host, 4 for child)
- [ ] 16GB+ RAM installed
- [ ] 2 physical disks connected (host + child/SD card)
- [ ] IOMMU groups visible: `ls /sys/kernel/iommu_groups/`
- [ ] SD card inserted (if testing on removable storage)

### Disk Identification (IMPORTANT)
- [ ] Identify host disk (DO NOT FORMAT): `lsblk` - root partition shows where / is mounted
- [ ] Identify child disk (WILL BE FORMATTED): secondary disk, typically /dev/sdb
- [ ] Set TARGET_DISK in config if needed: `TARGET_DISK="sdb"` in etc/proj-mk-ultra.conf
- [ ] Verify disk has no critical data (WILL BE DESTROYED)

### Software Verification
- [ ] Multikernel Linux v7.0-mk2 installed
- [ ] systemd init system active
- [ ] GRUB or systemd-boot configured
- [ ] Git installed
- [ ] debootstrap installed (if testing cross-distro Debian)
- [ ] dnf installed (if testing cross-distro Fedora)

### Repository Verification
- [ ] proj-mk-ultra directory exists
- [ ] 2_setup.sh is executable
- [ ] All scripts in pre-install/ are executable
- [ ] All scripts in prevention/ are executable
- [ ] All scripts in detection/ are executable
- [ ] All scripts in response/ are executable
- [ ] All scripts in update/ are executable
- [ ] All scripts in scripts/ are executable
- [ ] All scripts in useful-scripts/ are executable
- [ ] etc/proj-mk-ultra.conf exists

---

## Test Phase 1: Syntax Validation (Can run on any system)

### Script Syntax Check
- [ ] Run: `find . -name "*.sh" -type f -exec bash -n {} \;`
- [ ] All 41 scripts pass syntax check
- [ ] No syntax errors in 2_setup.sh

### File Integrity Check
- [ ] All 41 scripts are executable (chmod +x)
- [ ] Configuration file is readable
- [ ] Documentation files are present

---

## Test Phase 2: Host System Detection (Requires multikernel)

### Run Setup Wizard Phase 1
- [ ] Execute: `sudo ./2_setup.sh`
- [ ] System detection completes without errors
- [ ] Architecture detected as x86_64
- [ ] CPU cores detected correctly
- [ ] Memory detected correctly
- [ ] Disks detected correctly
- [ ] Multikernel support detected
- [ ] IOMMU status reported

### Verify Detection Output
- [ ] Host kernel version displayed
- [ ] Child disk identified (/dev/sdb or SD card)
- [ ] User data partition identified (/dev/sdb3)
- [ ] IOMMU groups listed

---

## Test Phase 3: Configuration (Can run on any system)

### Configuration File Test
- [ ] Run: `sudo ./scripts/load-config.sh`
- [ ] Config file loads without errors
- [ ] All variables exported correctly
- [ ] Run: `sudo ./scripts/save-config.sh`
- [ ] Config file updated successfully

### Security Level Presets
- [ ] Basic preset loads correctly
- [ ] Intermediate preset loads correctly
- [ ] Advanced preset loads correctly
- [ ] Filesystem selection available at each level

---

## Test Phase 4: Prevention Layer (Requires multikernel)

### IOMMU Verification
- [ ] Run: `sudo ./prevention/verify-iommu.sh`
- [ ] IOMMU enabled in kernel
- [ ] IOMMU groups detected
- [ ] VFIO driver available

### Module Signing
- [ ] Run: `sudo ./prevention/enforce-module-signing.sh`
- [ ] Module signing enforcement enabled
- [ ] Unsigned modules blocked

### Capability Dropping
- [ ] Run: `sudo ./prevention/setup-capability-dropping.sh`
- [ ] PrivateUsers=pick configured
- [ ] Capability=none configured
- [ ] DropCapability set correctly
- [ ] SystemCallFilter configured

### Filesystem Isolation
- [ ] Run: `sudo ./prevention/setup-filesystem-isolation.sh`
- [ ] ReadOnly=yes configured
- [ ] Volatile=yes configured
- [ ] Bind mounts configured

### Network Isolation
- [ ] Run: `sudo ./prevention/setup-network-isolation.sh`
- [ ] PrivateNetwork=yes configured
- [ ] Network isolation active

---

## Test Phase 5: Detection Layer (Requires running child)

### Resident Watcher (continuous enforcement)
- [ ] Install (path-rewrite to THIS repo clone, wherever it lives): `sudo sed "s|/opt/proj-mk-ultra|$(cd detection/.. && pwd)|" detection/suspicious-watch.service | sudo tee /etc/systemd/system/suspicious-watch.service && sudo systemctl daemon-reload && sudo systemctl enable --now suspicious-watch`
- [ ] Watcher running: `systemctl status suspicious-watch` (active, PID present)
- [ ] Watcher log live: `tail -f /var/lib/proj-mk-ultra/watch/watch.log`
- [ ] End-to-end: load an unsigned module inside the child → watcher logs RESPONSE TRIGGERED → auto-destroy flow runs → host taint stays 0
- [ ] Automated FSV run: `sudo ./scripts/first-spawn-validate.sh --pre-spawn` → spawn → re-run without flag → report shows PASS (paste back on FAIL/REVIEW)

### Boot Integrity Monitoring
- [ ] Run: `sudo ./detection/monitor-boot-integrity.sh`
- [ ] Boot hash computed
- [ ] Monitoring service started
- [ ] Log file created

### Hardware Isolation Monitoring
- [ ] Run: `sudo ./detection/monitor-hardware-isolation.sh`
- [ ] IOMMU status monitored
- [ ] VFIO status monitored
- [ ] Alerts configured

### Sysfs Access Monitoring
- [ ] Run: `sudo ./detection/monitor-sysfs-access.sh`
- [ ] Sysfs access logged
- [ ] Unauthorized access detected

### Module Loading Monitoring
- [ ] Run: `sudo ./detection/monitor-module-loading.sh`
- [ ] Module loading logged
- [ ] Unauthorized modules blocked

### Behavioral Anomaly Detection
- [ ] Run: `sudo ./detection/monitor-behavioral-anomalies.sh`
- [ ] Behavioral baseline established
- [ ] Anomaly detection active
- [ ] Alerts configured

---

## Test Phase 6: Response Layer (Requires running child)

### Auto-Destroy on Detection
- [ ] Run: `sudo ./response/auto-destroy.sh`
- [ ] Monitoring service started
- [ ] Anomaly detection active
- [ ] Auto-destroy configured

### Data Preservation
- [ ] Run: `sudo ./response/preserve-data.sh`
- [ ] Data preservation configured
- [ ] Backup mounts configured
- [ ] Recovery procedures documented

### Forensic Logging
- [ ] Run: `sudo ./response/forensic-logging.sh`
- [ ] Forensic logging configured
- [ ] Log rotation configured
- [ ] Log storage configured

### Recovery Procedures
- [ ] Run: `sudo ./response/recovery.sh`
- [ ] Recovery procedures documented
- [ ] Recovery scripts available
- [ ] Recovery tested

---

## Test Phase 7: Update System (Requires multikernel)

### Mainstream Kernel Update
- [ ] Run: `sudo ./update/update-mainstream.sh`
- [ ] Package manager detected
- [ ] Updates available checked
- [ ] Updates applied successfully

### Multikernel Update
- [ ] Run: `sudo ./update/update-multikernel.sh`
- [ ] Source repository found
- [ ] Updates available checked
- [ ] Updates applied successfully

### Child Kernel Sync
- [ ] Run: `sudo ./update/sync-child-kernel.sh`
- [ ] Child kernel synced
- [ ] Modules updated
- [ ] Configuration preserved

### Complete Kernel Update
- [ ] Run: `sudo ./useful-scripts/multi-kernel-update.sh status`
- [ ] Current kernel info displayed
- [ ] Run: `sudo ./useful-scripts/multi-kernel-update.sh update`
- [ ] All components updated
- [ ] Run: `sudo ./useful-scripts/multi-kernel-update.sh verify`
- [ ] Update verification passed

---

## Test Phase 8: Utility Scripts (Requires multikernel)

### Security Audit
- [ ] Run: `sudo ./scripts/security-audit.sh`
- [ ] Security audit completes
- [ ] All checks pass
- [ ] Report generated

### System Monitor
- [ ] Run: `sudo ./scripts/system-monitor.sh`
- [ ] System resources displayed
- [ ] Multikernel status shown
- [ ] Real-time monitoring works

### Boot Selector
- [ ] Run: `sudo ./scripts/suspicious-boot.sh`
- [ ] Boot menu displayed
- [ ] Options selectable
- [ ] Boot actions work

### Kernel Manager
- [ ] Run: `sudo ./useful-scripts/kernel-manager.sh list`
- [ ] Instances listed
- [ ] Run: `sudo ./useful-scripts/kernel-manager.sh monitor`
- [ ] Real-time monitoring works

---

## Test Phase 9: Filesystem Diversity (Requires multikernel)

### Leapfrog Configuration
- [ ] Enable leapfrog in setup wizard
- [ ] Host filesystem selected
- [ ] Child filesystem selected (different from host)
- [ ] Grandchild filesystem selected (different from child)

### Btrfs Snapshots (If using btrfs)
- [ ] Run: `sudo ./scripts/btrfs-snapshot.sh create test-snapshot`
- [ ] Snapshot created successfully
- [ ] Run: `sudo ./scripts/btrfs-snapshot.sh list`
- [ ] Snapshot listed
- [ ] Run: `sudo ./scripts/btrfs-snapshot.sh rollback test-snapshot`
- [ ] Rollback successful

### Cross-Distro Support (Optional)
- [ ] Enable cross-distro in setup wizard
- [ ] Select Debian or Fedora
- [ ] Run: `sudo ./scripts/create-debian-rootfs.sh`
- [ ] Debian rootfs created
- [ ] OR Run: `sudo ./scripts/create-rpm-rootfs.sh`
- [ ] Fedora rootfs created

---

## Test Phase 10: SD Card Testing (Requires SD card)

### Host Memory Reservation Prerequisite
- [ ] Host booted with child memory reserved: `movablecore=116G` (child + 36G scan slack) in the multikernel entry options line
- [ ] Both initramfs images validated BEFORE the reboot: `mkinitcpio -P` + `mkinitcpio -g <FULL initrd path>`
- [ ] Verify: `grep -A8 'zone.*Movable' /proc/zoneinfo | grep present` shows ~116GB
- [ ] Verify the machine's pool ceiling: `sudo ./scripts/probe-pool-ceiling.sh` (first SUCCESS = ceiling; set `CHILD_MEMORY_SIZE` to it)
- [ ] Verify: `free -g` shows host at ~45GB available after the baseline
- [ ] VM RAM allocation (if running) is well under the host's ~45GB post-baseline share (reference: 8GB VM verified; virt-manager memory changes require VM shutdown)

### Config Prerequisite
- [ ] Config generated or reviewed: `sudo useful-scripts/generate-config.sh` (dry-run shows detected RAM/CPU/disk/GPU/USB/NIC + the movablecore line) — or set the five hardware keys manually from `etc/proj-mk-ultra.conf.example` suggested defaults
- [ ] Loud-missing-parameter check: scripts abort with the exact key name, conf path, and suggested default when a required key is empty

### Multikernel Spawn Prerequisite
- [ ] Multikernel sysfs mounted: `mount -t multikernel none /sys/fs/multikernel`
- [ ] Config has real device paths: `grep -E "TARGET_DISK|CHILD_ROOT_DEVICE" etc/proj-mk-ultra.conf` (populated by partition-disk.sh)
- [ ] Host repo copy is the LATEST state (re-transferred after the last changes — a stale copy runs older preflights/docs)
- [ ] SD card inserted and enumerated as configured: `lsblk` shows TARGET_DISK (`sdb`)
- [ ] Spawn preflight passes: `sudo ./scripts/spawn-child-instance.sh --dry-run-check` aborts cleanly only if reservation missing

### SD Card Setup
- [ ] Run: `sudo ./scripts/sd-card-2_setup.sh`
- [ ] SD card detected
- [ ] Speed class verified
- [ ] Card formatted
- [ ] Partitions created

### Installation on SD Card
- [ ] Run setup wizard with SD card as target
- [ ] Installation completes successfully
- [ ] Child rootfs self-contained (kernel + initramfs in child /boot)
- [ ] Spawn path delivers child: `sudo ./scripts/launch-cycle.sh child-fsv` (boundary → spawn → boot → FSV; or suspicious-boot option 1 for spawn + `boot-instance.sh` for the boot)
- [ ] Device tree written with CHILD_CPU_MASK/CHILD_MEMORY_SIZE/PASSTHROUGH_PCI_DEVICES values
- [ ] Instance reaches status=running; host console reclaims USB on child exit

### Host Preservation
- [ ] Run: `sudo ./scripts/complete-uninstall.sh`
- [ ] All proj-mk-ultra files removed from host
- [ ] Systemd services removed
- [ ] Bootloader restored
- [ ] Host returns to pre-installation state

---

## Test Phase 11: Multi-Instance Support (Requires running child)

### Spawn Child Instance
- [ ] From within child kernel
- [ ] Run: `sudo ./scripts/spawn-child-instance.sh test-instance`
- [ ] New instance spawned
- [ ] Instance runs in isolated memory
- [ ] Shared /data partition accessible

### Instance Management
- [ ] List running instances
- [ ] Stop individual instances
- [ ] Restart instances
- [ ] Monitor instance resources

---

## Test Phase 12: Documentation Verification

### README.md Accuracy
- [ ] All script paths correct
- [ ] All command examples work
- [ ] Directory structure matches reality
- [ ] Security model description accurate
- [ ] Troubleshooting section helpful

### Filesystem Guide Accuracy
- [ ] Filesystem descriptions accurate
- [ ] Security properties correct
- [ ] Performance characteristics correct
- [ ] Use case recommendations appropriate

### Cross-Distro Guide Accuracy
- [ ] Supported distributions correct
- [ ] Requirements accurate
- [ ] Limitations documented
- [ ] Troubleshooting helpful

---

## Test Phase 13: End-to-End Workflow

### Complete Installation
- [ ] Boot from SD card or secondary disk
- [ ] Run 2_setup.sh
- [ ] Complete all 8 phases
- [ ] Verify installation summary

### Daily Workflow
- [ ] Run suspicious-boot.sh
- [ ] Launch child instance
- [ ] Work in isolated environment
- [ ] Stop child instance
- [ ] Run security audit

### Update Workflow
- [ ] Run multi-kernel-update.sh status
- [ ] Run multi-kernel-update.sh update
- [ ] Verify update
- [ ] Reboot and verify

### Recovery Workflow
- [ ] Simulate anomaly detection
- [ ] Auto-destroy triggers
- [ ] Data preserved
- [ ] Child rebuilt from recovery
- [ ] User data accessible

### GPU / NVIDIA Workflow (Phase 3 — Desktop/Laptop with NVIDIA GPU)
- [ ] Host kernel tainted = 0 confirmed (`cat /proc/sys/kernel/tainted`)
- [ ] Host uses nouveau only (no NVIDIA modules loaded)
- [ ] Child kernel boots successfully
- [ ] `nvidia-open-dkms` installed in child (`modprobe nvidia`)
- [ ] Child kernel tainted = 12288 after NVIDIA load (bits 12+13: O+E, NOT bit 0 because nvidia-open-dkms is GPL-compatible)
- [ ] Host kernel STILL tainted = 0 after child loads NVIDIA
- [ ] llama-server (llama.cpp) can see GPU inside child
- [ ] llama-server can run inference using CUDA inside child
- [ ] libvirt/QEMU VM can launch inside child
- [ ] VM can access GPU via VFIO passthrough (if configured)
- [ ] Child destroyed → NVIDIA taint disappears
- [ ] New child rebuilt fresh → cycle repeats
- [ ] Host remains tainted = 0 throughout entire lifecycle

### Uninstall Workflow
- [ ] Run complete-uninstall.sh
- [ ] Host pristine state restored
- [ ] No proj-mk-ultra files remain
- [ ] System boots normally

---

## Test Phase 14: Security Verification

### CBPI Prevention
- [ ] Namespace isolation verified
- [ ] Capability dropping verified
- [ ] Seccomp filtering verified
- [ ] Network isolation verified
- [ ] Filesystem isolation verified

### Hardware Isolation
- [ ] IOMMU active
- [ ] VFIO configured
- [ ] Child cannot access host disk
- [ ] Host can access child data (by design)

### Data Integrity
- [ ] User data persists across rebuilds
- [ ] Btrfs checksums detect corruption
- [ ] Snapshots preserve state
- [ ] Forensic logs preserved

---

## Test Phase 15: Performance Verification

### Resource Allocation
- [ ] Host cores assigned correctly
- [ ] Child cores assigned correctly
- [ ] Memory allocation correct
- [ ] No resource contention

### Boot Time
- [ ] Host boots in reasonable time
- [ ] Child boots in reasonable time
- [ ] Instance spawn time acceptable

### I/O Performance
- [ ] Disk I/O not degraded
- [ ] Network I/O not degraded (if enabled)
- [ ] Memory I/O not degraded

---

## Test Results Summary

| Phase | Status | Notes |
|-------|--------|-------|
| 1. Syntax Validation | | |
| 2. Host Detection | | |
| 3. Configuration | | |
| 4. Prevention Layer | | |
| 5. Detection Layer | | |
| 6. Response Layer | | |
| 7. Update System | | |
| 8. Utility Scripts | | |
| 9. Filesystem Diversity | | |
| 10. SD Card Testing | | |
| 11. Multi-Instance | | |
| 12. Documentation | | |
| 13. End-to-End | | |
| 14. Security | | |
| 15. Performance | | |

---

## Issues Found

| Issue | Phase | Severity | Description | Resolution |
|-------|-------|----------|-------------|------------|
| | | | | |
| | | | | |
| | | | | |

---

## Final Sign-Off

- [ ] All critical tests passed
- [ ] All major tests passed
- [ ] All minor tests passed
- [ ] Documentation verified
- [ ] Security verified
- [ ] Performance acceptable
- [ ] Ready for production use

**Tested by:** ______________________

**Date:** ______________________

**Signature:** ______________________
