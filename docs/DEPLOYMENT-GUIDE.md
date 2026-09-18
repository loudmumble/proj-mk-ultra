# PROJ-MK-ULTRA Deployment Guide

## Universal Zero-to-Child Walkthrough

**Version:** 2.0
**Updated:** September 7, 2026

This guide takes any x86_64 machine from stock hardware to a running,
hardware-isolated child kernel instance. It assumes nothing — if you have
never used Linux, start at section 1. If you are an experienced Linux user,
section 2 through 11 is the deployment sequence; the troubleshooting table
(section 12) contains every failure encountered during real deployment and
its fix.

**Framework loyalty:** every mechanism in this guide enforces an invariant
from the SUSPICIOUS Framework (https://github.com/loudmumble/cbpi-sus-pub).
Section 13 maps each enforcement point to the theory. Nothing here deviates
from the framework — it is the framework, implemented on Multikernel Linux
(https://github.com/multikernel/linux).

---

## 1. What You Are Building (and Why)

You are turning one computer into **two hardware-isolated computers**:

- A **host kernel** — the sovereign, permanently trusted side. It never loads
  anything untrusted. Its kernel taint counter stays at exactly `0` forever.
- A **child kernel** — an ephemeral, disposable work environment where AI
  agents, untrusted drivers, and experimental software run. It can be
  destroyed at any moment and everything wrong with it dies with it.

This is the Qubes OS idea pushed one layer down: instead of a hypervisor
separating VMs, **the multikernel capability of Linux** runs two full kernels
at once on one machine, each owning dedicated CPU cores, dedicated RAM, and
dedicated PCI devices.

Why this matters: software-level isolation (containers, namespaces, sandboxes)
is enforced by the kernel — the same component an attacker is trying to
compromise. Hardware-level isolation is enforced by physics: separate CPU
cores, carved RAM the host allocator never touches, and IOMMU-mediated device
access. A compromised child cannot walk out of its hardware box because there
is no software path out.

**The one-sentence invariant:** the host stays pristine (`tainted = 0`),
the child is disposable (`tainted = 12288` when NVIDIA loads), and every
piece of untrusted state dies with the child.

---

## 2. Concepts Primer (Coming from Windows)

| Windows concept | Linux equivalent here | What it does |
|-----------------|----------------------|--------------|
| `C:\` drive | `/` (the root filesystem) | Where the OS lives |
| D: drive, USB stick | `/dev/sdb` (a second disk) | The child's dedicated disk |
| Boot menu (F8 at startup) | **systemd-boot** (`/boot/loader/`) | Picks which kernel starts |
| Registry | Config files (`/etc/`) | System settings |
| Device Manager | `lspci`, `lsusb` | Lists hardware |
| Task Manager | `htop`, `free -h` | Shows CPU/RAM usage |
| Services (`services.msc`) | systemd (`systemctl`) | Background processes |
| Command Prompt / PowerShell | Terminal (bash shell) | Where you type commands |
| "Run as Administrator" | `sudo` | Execute with elevated rights |

Conventions used below: lines starting with `#` are comments; lines starting
with `$` are commands you type; `Ctrl+C` stops a running command.

You will need a terminal. On an Arch Linux desktop: `Ctrl+Alt+T` or your
application menu → Terminal.

---

## 3. Hardware Requirements

| Requirement | Minimum | This guide's reference build |
|-------------|---------|------------------------------|
| Architecture | x86_64 only | x86_64 |
| CPU | IOMMU-capable (Intel VT-d / AMD-Vi), 4+ cores | Intel i9-14900KF (24 cores / 32 threads) |
| RAM | 16GB | 128GB (4×32GB) |
| Disks | 2+ physical disks | Host NVMe + 32GB SD card (USB reader) |
| GPU | One display-capable GPU | NVIDIA RTX 4090 (nouveau on host) |
| Boot mode | UEFI (GPT) | systemd-boot |

Notes:
- The reference build uses an **Intel "F"-series CPU (no integrated
  graphics)** — the display GPU is also the compute GPU. Sections 6 and 13
  cover the GPU driver arrangement this forces.
- **SD card first** is the recommended entry path: it is recyclable and
  replaceable. If anything fails, re-flash and retry at zero cost. Graduate
  to a dedicated NVMe only after the SD card test passes.

---

## 4. BIOS / UEFI Setup

Reboot into BIOS/UEFI (usually `Del` or `F2` during POST):

1. **Enable VT-d** (Intel) or **AMD-Vi/IOMMU** (AMD) — required for device
   passthrough. Without it, the child cannot own hardware.
2. **Enable VT-x** (Intel) or **SVM** (AMD) — required for VMs inside the child.
3. If present, enable **Per P-core Control / Per E-core Control /
   Per P-core Hyper-Threading Control** — gives the CPU partitioning full
   granularity.
4. **Secure Boot: leave as-is.** If it is on and your kernel boots, module
   signing is handled by the prevention layer. If it is off, leave it off.
   Do not flip it mid-deployment.

Save and exit.

---

## 5. Host OS Prerequisites

The reference host is **Arch Linux with systemd-boot** (not GRUB). Other
distributions work — the scripts detect pacman/apt/dnf — but bootloader
examples below are systemd-boot.

### 5.1 Kernel parameters

Edit the multikernel boot entry (the file the boot menu selects):

```bash
sudo nano /boot/loader/entries/YOUR-MULTIKERNEL-ENTRY.conf
```

The `options` line must contain **all** of the following:

```
intel_iommu=on iommu=pt movablecore=116G nouveau.config=NvGpuRm=1
```

(AMD systems: `amd_iommu=on` instead of `intel_iommu=on`.)

| Parameter | Why |
|-----------|-----|
| `intel_iommu=on` / `amd_iommu=on` | Turns on the hardware DMA isolation that makes passthrough safe |
| `iommu=pt` | Passthrough mode for host devices — host keeps full performance |
| `movablecore=116G` | **Memory sequestration** — see section 7. Places 116GB (child + scan slack) in ZONE_MOVABLE, the exclusive source the multikernel baseline draws the child's pool from; the slack returns to the host after the baseline |
| **Fork constant (required for child pools > ~64G)** | Patch `MK_CTRL_PGTABLE_PAGES 64 → 256` in `arch/x86/include/asm/multikernel.h` and rebuild — see section 7. Not CMA: the ~80G contig claim succeeds at boot on `movablecore` alone; the original blocker was the identity page-table array (one page-table page per GB, 64 entries) |
| `nouveau.config=NvGpuRm=1` | Lets nouveau load NVIDIA GSP firmware on Ada Lovelace (RTX 40 series) GPUs |

**Never put `vfio-pci.ids=...` on the host command line.** That would steal
the GPU (or USB controller) away from nouveau at boot and destroy the host
display. Device binding happens at spawn time, not boot time.

### 5.2 initramfs (mkinitcpio)

The VFIO modules must be inside the initramfs so they are available at early
boot:

```bash
sudo nano /etc/mkinitcpio.conf
# MODULES=(vfio vfio_iommu_type1 vfio_pci)
sudo mkinitcpio -P
```

(`vfio_virqfd` no longer exists in modern kernels — it merged into `vfio`.
If you see `module not found: 'vfio_virqfd'`, that is why.)

### 5.3 Verify after reboot

```bash
dmesg | grep -i iommu          # IOMMU enabled
ls /sys/kernel/iommu_groups/   # groups exist
lsmod | grep vfio              # vfio modules loaded
cat /proc/sys/kernel/tainted   # must print 0
```

### 5.4 One-Reboot Deployment Order

Every host-side change below can be staged before a single reboot — do not
reboot between steps 1-4:

```
1. Edit the multikernel boot entry options line (section 5.1)
2. Validate BOTH initramfs images build clean:
     sudo mkinitcpio -P
     sudo mkinitcpio -g /boot/<machine-id>/7.0.0-mk2-g<hash>/initrd
   (mkinitcpio -g requires the FULL initrd file path — a "mk-7.0.0-g4..."
    shorthand is rejected. The rebuilds are only strictly required when
    /etc/mkinitcpio.conf changed since the last build, but running them
    here proves both images build before you commit to the reboot.)
3. Host VM: shut it DOWN, then set its allocation in virt-manager
   (reference: 8GB). The Memory field is a cold change — it requires the
   VM powered off, not rebooted.
4. Reboot the host — ONE reboot activates the kernel parameters, the
   initramfs images, and the ZONE_MOVABLE split simultaneously.
5. Verify (5.3 + section 7):
     grep -A8 'zone.*Movable' /proc/zoneinfo | grep present && free -g   # 116GB movable zone
     uname -r                                               # mk2 kernel
     cat /proc/sys/kernel/tainted                           # 0
6. Boot the host VM (8GB) if you work through a VM.
7. Transfer the LATEST repo state to the host (section 8).
8. Insert the SD card and confirm its device name (section 8).
9. sudo ./2_setup.sh (section 8).
```

---

## 6. Building the Multikernel

Follow the official getting-started (https://multikernel.io/getting-started.html)
against https://github.com/multikernel/linux:

1. Clone, check out `v7.0-mk2` (or newer).
2. Enable in the kernel config:
   - `CONFIG_MULTIKERNEL=y`
   - `CONFIG_MULTIKERNEL_VSOCKETS=y` — if the build process demotes this to
     `=m` (module), that is fine; modules load on demand.
   - `CONFIG_OF=y` and `CONFIG_OF_OVERLAY=y` (device-tree support — instance
     configuration is written as device-tree overlays)
   - MKTTY support as directed by the guide
3. Build, `make modules_install install`, rebuild initramfs, add the boot
   entry (section 5.1), reboot into it, verify `uname -r` contains `mk2`.

**Known gotcha:** the multikernel kernel's initramfs is NOT rebuilt by
`mkinitcpio -P` (that only handles packaged kernels with presets). Rebuild it
directly at the installed path:

```bash
# Find the multikernel initrd (systemd-boot BLS layout)
ls /boot/*/*/initrd            # e.g. /boot/<machine-id>/7.0.0-mk2-g<hash>/initrd
sudo mkinitcpio -g /boot/<machine-id>/7.0.0-mk2-g<hash>/initrd
```

**Known gotcha:** `/boot` runs out of space fast with multiple kernels.
Old kernel directories (`/boot/<machine-id>/7.0.0-mk2-g<OLDHASH>`) are safe
to remove once the new one boots. Symptoms of a full /boot:
`cat: write error: No space left on device` during image generation.

---

## 7. Memory Sequestration (The Load-Bearing Wall)

**This is not optional.** Peripherals handed to the child are isolated by the
IOMMU — hardware-enforced. Memory has no IOMMU equivalent: both kernels are
ring-0 peers that can decode the whole RAM address space. The boundary is the
multikernel pool: the host baseline donates the child's RAM to the pool and
the allocator never returns it. That boundary must exist **before any
workload**, and its source must be reserved **at boot**.

### The mechanism (three deterministic steps)

```
1. BOOT         movablecore=116G   ->  the top 116GB enters ZONE_MOVABLE
                                        (a zone that holds only migratable
                                        pages - by definition clean for
                                        contiguous allocation)
2. BASELINE     mk-baseline.service writes the baseline DTB to
                /sys/fs/multikernel/device_tree at boot, BEFORE the desktop
                session ->  the kernel contig-allocates CHILD_MEMORY_SIZE (81917M reference) from
                    ZONE_MOVABLE into the multikernel pool (marked
                    IORESOURCE_BUSY, never returned to the allocator).
                The chunk equals the whole zone, so application must happen
                while the zone holds no pinned pages - after session start
                (GPU DMA, mlock), late application races the session and
                fails with ENOMEM.
3. INSTANCE     host writes an instance overlay to /sys/fs/multikernel/overlays/new
                ->  instance-create draws the child's memory and CPUs from
                    that pool; the child kernel owns them exclusively
```

Without the boot reservation, the host treats the top RAM as general-purpose:
spawning a child with "dedicated" memory silently overlaps the host's page
cache, your open VMs, or application memory — two ring-0 kernels mapping the
same physical page. The result is silent corruption with no taint, no oops,
and no trace: exactly the class of failure the SUSPICIOUS Framework exists to
make impossible.

The boundary is **kernel-enforced and deterministic**: the pool chunk is
either fully allocated at baseline (boundary exists, verifiable in dmesg and
`/proc/iomem`) or the baseline fails loudly (no instance, no partial state).
Between boot and baseline the top RAM is ordinary movable memory — closed by
applying the baseline immediately at boot, before any workload, which the
deployment flow does. After the baseline, the page allocator structurally
cannot hand those frames to any host process.

### The math (128GB host)

```
movablecore=116G
│             │
│             └── host runs in the remainder (~12GB non-movable base at boot;
│                 the unused ~36GB of ZONE_MOVABLE returns to it after the
│                 baseline)
└─────────── child's pool source: 116GB enters ZONE_MOVABLE at boot
             (the ~80GB contig window gets 36GB of dodge room - a window
              near the zone size cannot avoid early-userspace pages; the
              reference 112GB/116GB split failed exactly this way - run
              scripts/probe-pool-ceiling.sh on a new machine)
```

`movablecore` takes its share from the **top** of memory, so the child pool
lands in the highest address range — same layout the address-carve designs
target, but through the zone machinery this multikernel actually allocates
from. Consumer memory controllers interleave channels across all DIMMs, so
the split is by **address range**, not physical stick. Isolation is
unaffected: after the baseline, the host never allocates those frames and the
child's page tables map them exclusively.

### Verify

```bash
grep -A8 'zone.*Movable' /proc/zoneinfo | grep present   # ~116GB in the movable zone
free -g                   # host sees ~45GB
sudo dmesg | grep 'Multikernel pool: added'   # after baseline: <CHILD_MEMORY_SIZE MB> on node 0
cat /proc/iomem | grep -i multikernel         # pool chunk registered IORESOURCE_BUSY
```

### Cautions

- Keep any VMs on the host well under the ~45GB share (reference: 8GB VM — verified) so the host's post-baseline share is never exhausted.
- Changing a VM's allocation in virt-manager requires the VM powered OFF — the Memory field is a cold change, not a live adjustment.
- Hibernate/suspend with a movablecore split is untested — verify before relying on it.
- The spawn preflight (`spawn-child-instance.sh`) **aborts** if ZONE_MOVABLE
  cannot cover the child. The override (`MEMORY_RESERVATION_ACKNOWLEDGED="true"`
  in the config) exists only for platforms that reserve memory by another
  mechanism.
- The baseline is applied at boot by `mk-baseline.service` (deterministic,
  pre-session). `spawn-child-instance.sh` keeps an identical idempotent
  fallback: it applies the baseline on spawn only if the pool is not yet
  populated, and skips cleanly when it is.

---

## 8. Installing PROJ-MK-ULTRA

```bash
git clone https://github.com/loudmumble/proj-mk-ultra.git
cd proj-mk-ultra
sudo ./2_setup.sh
```

**Config first (optional, two paths):**
1. **Auto-generate from this machine's hardware:** `sudo useful-scripts/generate-config.sh` (dry-run) detects RAM/CPU/disk/GPU/USB slots and prints the exact conf + the movablecore boot param; add `--write` to install it (backs up any existing conf).
2. **Manual:** start from `etc/proj-mk-ultra.conf.example` (generic suggested defaults) — copy to `etc/proj-mk-ultra.conf` and set the five hardware keys for your machine.

`etc/proj-mk-ultra.conf` pre-fills every wizard
answer. Keys are `UPPER_SNAKE_CASE` — they are sourced as bash, so hyphens
are illegal. Defaults for the reference build: `btrfs` host filesystem,
`basic` security level, `/dev/sdb` target, 81917M child memory (reference build). Every key is
documented in [BUILD-CUSTOMIZATION.md](BUILD-CUSTOMIZATION.md).

**Transfer the latest state.** This guide describes the current repo — before
running the wizard, confirm the host copy matches your newest build (re-tar
from your working VM/dev machine, or `git pull` on the host). A stale host
copy silently runs older preflights and older documentation.

**Confirm the target disk name.** `TARGET_DISK` in `etc/proj-mk-ultra.conf`
is the bare device name (`sdb`). After inserting the SD card, run `lsblk` and
confirm it enumerated as expected — the disk-selection logic uses the
configured name when that block device exists and falls back to interactive
selection (with a clear warning) when it does not.

The wizard walks 8 phases; the interactive prompts:

1. **System detection** — distro, arch, multikernel, IOMMU, VFIO, systemd.
   Multikernel detection uses `zgrep` on `/proc/config.gz` (plain `grep`
   cannot read the compressed file — a past bug, now fixed and guarded).
2. **Configuration** — security level (basic/intermediate/advanced),
   filesystems (btrfs/ext4 leapfrog is the recommended pairing), install
   target, and **child hardware assignment**: memory (81917M reference - derive your ceiling with `scripts/probe-pool-ceiling.sh`), CPU mask
   (`0xFFFFFFF0` — host keeps CPUs 0-3), PCI devices (`01:00.0` — the GPU,
   display handoff by default; append `00:14.0` for USB-root deployments). The wizard prints the exact
   `movablecore=` line your selection requires.
3. **Pre-installation** — verifies the memory reservation (advisory here,
   hard abort at spawn), mounts multikernel sysfs, installs
   mk-baseline.service (boot-time pool boundary, pre-session), then
   partitions the target disk (`partition-disk.sh`) and installs the child rootfs
   (`install-child-kernel.sh`).
4. **Prevention / 5. Detection / 6. Response / 7. Update** — the three
   SUSPICIOUS layers plus update plumbing.
8. **Final verification** — checks scripts, config completeness, spawn path.

Answer the target-disk prompt carefully: it is the **SD card / secondary
disk**, never the host's root disk. `partition-disk.sh` requires typing
`YES` before it touches anything.

---

## 9. What the SD Card Deployment Creates

```
/dev/sdb (32GB SD card)
├── p1  512MB   FAT32   child /boot     kernel + initramfs (self-contained)
├── p2   10G    btrfs   child root /   ephemeral — destroyed on anomaly
└── p3  ~21G    btrfs   child /data    persistent user data — survives rebuilds
```

- The child root receives the multikernel kernel, its module tree, and a
  generated initramfs — the child is bootable both via multikernel spawn and
  standalone (best-effort EFI bootloader for recovery on any UEFI machine).
- The devices are persisted back into `etc/proj-mk-ultra.conf`
  (`TARGET_DISK`, `CHILD_*_DEVICE`) so every later script uses real paths,
  never hardcoded fallbacks.
- **Leapfrog** (intermediate+ security level): the child partitions are
  formatted with a *different* filesystem than the host, so a metadata
  poisoning payload built for the host filesystem cannot cross the boundary.

---

## 10. Spawning the Child

```bash
# One-time: mount the multikernel control filesystem
sudo mount -t multikernel none /sys/fs/multikernel

# Preflight (no instance created)
sudo ./scripts/spawn-child-instance.sh --check

# Spawn
sudo ./scripts/suspicious-boot.sh     # option 1
#   or directly:
sudo ./scripts/spawn-child-instance.sh child-$(date +%s)
```

What the spawn does:

1. **Preflights** — sysfs present; ZONE_MOVABLE covers the child memory
   (hard abort otherwise); physical APIC IDs resolve from the CPU mask;
   `CHILD_ROOT_DEVICE` exists; passthrough list contains no host root/NIC.
2. **Applies the baseline** (first spawn only) — donates the child's CPUs
   and ZONE_MOVABLE memory to the multikernel pool via
   `/sys/fs/multikernel/device_tree`; skipped when the pool is populated.
3. **Submits the instance overlay** to
   `/sys/fs/multikernel/overlays/new`: instance-create draws the child's
   memory and CPUs from the pool; the kernel creates
   `/sys/fs/multikernel/instances/<name>/`.
   (`multikernel.role=child`). The SUSPICIOUS triple-lock
   (`private-users=pick`, `capability=none`, `private-network=yes`) is
   enforced by the child rootfs and the blueprints from cbpi-sus-pub
   (`install-child-kernel.sh` disables child-side network/SSH services;
   `local_agent.nspawn` carries the full config) — on top of the kernel
   boundary itself, which is the hard isolation the blueprint triad
   supplements.
3. **Boot separately** with `scripts/boot-instance.sh <name>`: it moves the
   `PASSTHROUGH_PCI_DEVICES` into the child (`device-add` overlay targeting
   `/instances/<name>`), releases host drivers at the boot instant (default:
   deferred to the core — `SPAWN_KEEP_BOUND=true`), writes the boot command
   in the background (the control write runs the child boot inside the
   syscall), polls status to `running`, then starts the `/dev/mktty` console
   capture.

What you experience depends on the display mode — choose deliberately:

**Display-handoff (default: `PASSTHROUGH_PCI_DEVICES="01:00.0"` — the GPU):**
spawn hands the GPU to the child — the screen blanks at child boot, then the
**child owns the display** and its boot messages scroll. This is the
Qubes-style takeover: the child IS the machine; the host is a headless
launch-pad (SSH is the host's control channel — verify it is up BEFORE the
handoff). On child exit the device returns and udev rebinds the driver.
Append the USB controller for USB-root child deployments
(`PASSTHROUGH_PCI_DEVICES="01:00.0 00:14.0"`) — the child then also gets
keyboard/mouse/SD reader. Marked FIRST-SPAWN VALIDATION: the multikernel
core's handling of bound devices at handoff is unproven until the first
real spawn — `SPAWN_KEEP_BOUND=true` (default) keeps host drivers bound
and lets the core manage the handoff itself.

**Headless-child (`PASSTHROUGH_PCI_DEVICES=""` or any non-GPU slot):** the
child has NO display device — its boot messages go nowhere visible. The
host keeps the GPU and its session; you interact with the child through the
tools that reach it (instance sysfs status; a future serial/vsock console).
Choose this for pure isolation testing.

---

## 10b. Resident Watcher (Continuous Detection)

The detection monitors are one-shot checks. Continuous enforcement comes from
`detection/resident-watch.sh` (run by `suspicious-watch.service`):
every interval it verifies host taint == 0, boot-file hashes against the
baseline, and child instance states — any violation triggers the response
layer (auto-destroy → preserve → forensic → relaunch).

```bash
sudo cp detection/suspicious-watch.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now suspicious-watch
journalctl -u suspicious-watch -f          # watch it work
```

Module-signing enforcement chain (honest summary): enforcement is the kernel
cmdline flag `module.sig_enforce=1`; signing uses the kernel tree's
sign-file with the generated key; the key must be TRUSTED to be accepted —
Secure Boot hosts enroll it via `prevention/enroll-mok.sh` (MOK, physical
reboot step by design), non-SB hosts via `CONFIG_SYSTEM_TRUSTED_KEYS` wired
automatically by `pre-install/build-multikernel.sh` at build time.

### Obsidian vault filtering (RPI recovery path)

For poisoned Obsidian notebooks on the RPI: `equilibrium obsidian <vault-path>`
scans every .md file for metadata/attribute/owner/group poisoning, hidden
Unicode (Trojan Source class), frontmatter anomalies, active HTML, backtick
commands, and prompt-injection markers — per-file verdict CLEAN / REMEDIABLE /
QUARANTINE. Non-destructive: it flags, it never modifies. Review in Obsidian
or grimoire after quarantine.

### First-spawn validation protocol (AUTOMATED)

Five runtime behaviors cannot be proven offline. They are validated by one
script — run it, read the report:

```bash
sudo ./scripts/first-spawn-validate.sh --pre-spawn   # BEFORE spawning (baseline)
sudo ./scripts/spawn-child-instance.sh child-fsv     # the first spawn
sudo ./scripts/first-spawn-validate.sh               # evaluates FSV-1..5
```

The report prints PASS/FAIL/REVIEW per check with the evidence and the exact
next command on failure. What each check covers:

1. **FSV-1 child-halt semantics**: uptime continuity + instance disappearance
   = child halt == instance exit with host survival. An uptime reset means
   child halt powered off the machine (report — exit path switches to
   host-side stop).
2. **FSV-2 sysfs API**: instance status=running + config present = the core
   accepted the DT; a FAIL names the dmesg command that identifies the
   rejected field (fix = the single DT heredoc in spawn-child-instance.sh).
3. **FSV-3 GPU handoff**: driver release verified via sysfs (unbound = child
   owns the device); `SPAWN_KEEP_BOUND=true` documented bypass.
4. **FSV-4 USB handoff/reclaim**: input-device count delta vs the
   pre-spawn baseline (fewer = handed to child; equal post-exit = reclaimed).
5. **FSV-5 watcher end-to-end**: service active, log recording, host taint
   invariant held.

Human gate = reading the report. Paste it back ONLY on FAIL/REVIEW lines.
## 11. Verifying the Invariants

```bash
# On the HOST (while child runs, from a VM or SSH):
cat /proc/sys/kernel/tainted        # must be 0 — ALWAYS

# On the CHILD:
cat /proc/sys/kernel/tainted        # 12288 with nvidia-open-dkms loaded
mount | grep -E "sdb|nvme"          # child sees only its own disk
ls /dev/sda 2>&1                    # No such file — host NVMe invisible
```

| Invariant | Enforcement |
|-----------|-------------|
| Host taint = 0 forever | Host loads nouveau only; NVIDIA modules live only in the child; child is ephemeral |
| Child cannot reach host data | Host NVMe never in the passthrough list; separate physical disks |
| Untrusted code cannot persist | Child root is ephemeral; user data lives on a separate partition the host can inspect |
| Memory corruption cannot cross kernels | Boot-time ZONE_MOVABLE reservation + baseline pool, verified by spawn preflight |
| Devices cannot DMA across boundaries | IOMMU (VT-d/AMD-Vi) + per-device passthrough list |

---

## 12. Troubleshooting (Every Failure From Real Deployment)

| Symptom | Cause | Fix |
|---------|-------|-----|
| `nouveau gsp: Failed to load required firmware ... error -22` | Ada Lovelace (RTX 40xx) needs GSP firmware loading enabled | Add `nouveau.config=NvGpuRm=1` to the kernel entry options |
| Display stuck at 1024x768, one monitor | nouveau failed; X fell back to modesetting on a fallback framebuffer | Same as above — the GPU driver never initialized |
| Display destroyed after boot param edit | `vfio-pci.ids=` on the host cmdline stole the GPU before nouveau | Remove it from the HOST entry; passthrough happens at spawn, not boot |
| `No space left on device` during initramfs build | /boot full of old kernels | Remove old `/boot/<machine-id>/7.0.0-mk2-g<OLDHASH>/` dirs |
| `config: line 6: core-host-filesystem=btrfs: command not found` (×34) | Config keys used hyphens — invalid bash | Fixed in v2.0; keys are `UPPER_SNAKE_CASE`. If resurfacing, you have a stale conf — re-copy the repo |
| `/var/lib/proj-mk-ultra/setup-state/detection: No such file or directory` | Older setup.sh created only the parent dir | Fixed in v2.0 (`mkdir -p "${STATE_FILE}"`) |
| `Multikernel support: Not detected` despite running mk kernel | Plain `grep` cannot read gzip'd `/proc/config.gz` | Fixed in v2.0 (zgrep + sysfs + uname fallbacks) |
| Spawn aborts: `ZONE_MOVABLE holds ...GB but child needs ...` | No `movablecore=` on host cmdline, or zone too small | Add `movablecore=116G` (reference) to the multikernel entry, reboot, re-verify (section 7) |
| `Waiting 10 seconds for device /dev/mapper/root` loop at boot | Initramfs lacks modules or cmdline is broken | Boot a prior kernel, fix options line, rebuild initramfs (section 5.2, 6) |
| `mkinitcpio -g` says "must be writable" / "not a directory" | Target path confusion — `-g` wants the exact initrd file path | `sudo mkinitcpio -g /boot/<machine-id>/7.0.0-mk2-g<hash>/initrd` |
| `ERROR: '/lib/modules/<ver>' is not a valid kernel module directory` | Running mkinitcpio against a version whose modules are absent | Rebuild against the running kernel or the path that exists (`ls /lib/modules/`) |
| Child boot: status never becomes running | DT field rejected by multikernel core | `dmesg | grep -i multikernel` names the field; adjust the DT heredoc in spawn-child-instance.sh |
| `mkinitcpio -g` rejects a `mk-7.0.0-g4...`-style argument | `-g` requires the full initrd file path, not a kernel-name shorthand | `sudo mkinitcpio -g /boot/<machine-id>/7.0.0-mk2-g<hash>/initrd` |
| virt-manager Memory change will not apply | VM allocation is a cold change | Power the VM OFF fully, set the allocation, then start it — rebooting the guest is not sufficient |

---

## 13. Mapping to the SUSPICIOUS Framework

Framework reference: https://github.com/loudmumble/cbpi-sus-pub
(documents/, blueprints/).

| CBPI vulnerability class | This deployment's enforcement |
|--------------------------|-------------------------------|
| Compositional Boundary Precedence Inversion (config claims a boundary it cannot enforce) | Every boundary here is claim-then-verify: the spawn preflight aborts when ZONE_MOVABLE cannot cover the child; `CHILD_ROOT_DEVICE` must exist as a block device; config completeness is validated in the final phase |
| Dual-Master Agentic Paradox (split brain/cloud trust) | The child has `private-network=yes` by default — no remote master; the host kernel is the single local trust root |
| Identity-collision attacks (UID == UID across a soft boundary) | Separate kernels: the child's UID space cannot collide with the host's because there is no shared kernel to arbitrate — plus `private-users=pick` inside the child |
| Privilege escalation | `capability=none` in the nspawn blueprint (child rootfs hardening); unsigned module loading monitored and blocked on the host |
| Persistence after compromise | Child root is ephemeral by design; destroy = `boot-instance.sh --destroy` (graceful `shutdown` control write, overlay-remove fallback); taint dies with the child |
| Memory-layer boundary inversion | `movablecore=` boot reservation + baseline pool + preflight — after the baseline, the host allocator provably never owns child frames |

Sovereign-runtime alignment (local-only master, transparent prompts,
user-owned model weights) is preserved because the child is a full Linux
userspace the user controls end-to-end — the framework's triple-lock
(namespace virtualization, syscall filtering, read-only root) is expressed
in the DT security block and hardened further by the fact that the isolation
substrate is the kernel boundary itself, not a process inside it.

---

## 14. Lifecycle Reference

```bash
# Spawn (from host)
sudo ./scripts/spawn-child-instance.sh my-agent

# Inspect
cat /sys/fs/multikernel/instances/my-agent/status

# Graceful stop (from host)
echo shutdown > /sys/fs/multikernel/instances/my-agent/control
# Forced:
echo force-shutdown > /sys/fs/multikernel/instances/my-agent/control

# Menu-driven control
sudo ./scripts/suspicious-boot.sh

# Nested spawn (from inside a child)
sudo ./scripts/spawn-child-instance.sh grandchild-1

# Full uninstall
sudo ./scripts/complete-uninstall.sh
```

---

## 15. FAQ

**Q: Why not just use Qubes/VirtualBox/Docker?**
A: Docker shares the host kernel (one exploit = host). Type-2 hypervisors
share the host kernel too. Qubes is closest, but requires Xen below Linux;
the multikernel approach puts the isolation in the Linux kernel itself with
no hypervisor layer — smaller trusted computing base, native performance.

**Q: Can the child infect the host through the SD card?**
A: The child's poisoned filesystem cannot leapfrog to the host: different
kernel, different partition, and (with leapfrog enabled) a different
filesystem whose metadata the payload was not built for. The host may mount
`/dev/sdb3` (user data) read-only for inspection — by design.

**Q: What happens when the child detects an anomaly?**
A: The response layer destroys the child, preserves user data, writes forensic
logs, and (optionally) relaunches a clean child. Host state is untouched.

**Q: Where do my files actually live?**
A: `/dev/sdb3` — the persistent partition. Child rebuilds and destructions
never touch it. Back it up from the host with `mount /dev/sdb3 /mnt/...`.

**Q: Can I run this on a laptop?**
A: Yes, if it meets section 3 (IOMMU-capable, 2 disks or a large SD card).
The SD card path exists precisely for machines you cannot repartition.

**Q: What belongs in this repository — and what doesn't?**
A: Curated documentation (`docs/`), scripts, and configuration. Raw session
logs, working notes, and intermediate artifacts do not — keep them outside
the repository you deploy from. The repo should contain exactly what a fresh
machine needs and nothing else; this guide and the docs index are the
complete guidance surface.
