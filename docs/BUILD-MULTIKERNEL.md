# Building the Multikernel Kernel

## Fork constant (REQUIRED for child pools > ~64G)

The multikernel identity page table allocates one page-table page per GB of
pool at 2MB pages, from a fixed array bounded by `MK_CTRL_PGTABLE_PAGES`
(arch/x86/include/asm/multikernel.h — default 64). Pools larger than ~64GB
exceed it: the baseline claims the chunk, then `mk_arch_pool_chunk_added` →
`mk_ident_map_range` fails and the kernel returns the memory
(`Multikernel pool: removed` follows the war). Patch before building:

```
arch/x86/include/asm/multikernel.h
- #define MK_CTRL_PGTABLE_PAGES	64
+ #define MK_CTRL_PGTABLE_PAGES	256
```

Then rebuild, reinstall, regen the initramfs, reboot. 256 covers ~250GB of
pool at 2MB pages. (Reference: 16GB pools work unpatched — the 16G baseline
is how the bound hides until a bigger child is attempted.)

## Kernel source acquisition for PROJ-MK-ULTRA

**Credit:** the base procedure follows the official Getting Started guide at
https://multikernel.io/getting-started.html (Multikernel Technologies). This
document adapts it for PROJ-MK-ULTRA: pinned commit, config fragment, and the
bootloader specifics this deployment requires.

---

## Reproducibility lock (no vendoring)

| Piece | Location | Purpose |
|-------|----------|---------|
| **Pinned commit** | `4bc24ec0b394` | The exact upstream source the validated kernel `7.0.0-mk2-g4bc24ec0b394` was built from. The build script checks out this commit — upstream drift cannot change what you build. |
| **Config fragment** | `config/multikernel-proj-mk-ultra.fragment` | The required CONFIG_* deltas, merged via `scripts/kconfig/merge_config.sh`. Never edit upstream files. |
| **Build script** | `pre-install/build-multikernel.sh` | Fetches the pin → merges the fragment → verifies required flags → builds → installs → creates the BLS boot entry → rebuilds initramfs. |
| Fork policy | — | **Deferred.** No fork while requirements are config-only. A fork (or patch-queue) is needed only if the multikernel core itself requires source changes. Upstream contribution of the integration is the long-term path. |

---

## Build dependencies (per distribution)

| Distro | Packages |
|--------|----------|
| Arch / Manjaro / EndeavourOS | `base-devel bc bison flex libelf openssl zstd cpio perl git kmod` |
| Debian / **Kali** / Ubuntu | `build-essential libncurses-dev bison flex libelf-dev libssl-dev zstd cpio kmod dwarves git` |
| Fedora / RHEL / CentOS | `@development-tools bc bison flex elfutils-libelf-devel openssl-devel zstd cpio kmod dwarves git` |

Kali users: Kali is Debian-based — use the Debian package line and the `deb`
tooling variant. `mk-susboot/install.sh` maps `kali*` → `deb` automatically.

---

## Step 1: Build the kernel (adapted from multikernel.io Getting Started)

```bash
# 1. Fetch the pinned source
git clone --filter=blob:none https://github.com/multikernel/linux.git /opt/multikernel/linux
cd /opt/multikernel/linux
git checkout 4bc24ec0b394

# 2. Base config, then merge the PROJ-MK-ULTRA fragment
#    Base is vanilla defconfig BY DESIGN - distro-seeded configs drop most
#    symbols on vanilla source (evaluated and removed as a misfeature).
#    Manual review step: MENUCONFIG=1 ./build-multikernel.sh launches
#    menuconfig after the merge - review/toggle, SAVE, build continues.
make defconfig
scripts/kconfig/merge_config.sh -m .config \
    /home/<you>/proj-mk-ultra/config/multikernel-proj-mk-ultra.fragment
make olddefconfig

# 3. VERIFY the required flags before compiling (non-negotiable)
for opt in CONFIG_MULTIKERNEL=y CONFIG_OF=y CONFIG_OF_OVERLAY=y CONFIG_KEXEC=y; do
    grep -q "^${opt}$" .config || { echo "MISSING: ${opt}"; exit 1; }
done
grep -qE "^CONFIG_MULTIKERNEL_VSOCKETS=(y|m)$" .config || { echo "MISSING: VSOCKETS"; exit 1; }
# Config visibility (verified here and by every zgrep check in this repo):
grep -q "^CONFIG_IKCONFIG=y$" .config && grep -q "^CONFIG_IKCONFIG_PROC=y$" .config \
    || { echo "MISSING: IKCONFIG/IKCONFIG_PROC"; exit 1; }

# 4. Build and install
make -j"$(nproc)"
sudo make modules_install install
```

## Step 2: Boot entry (systemd-boot)

Create `/boot/loader/entries/multikernel.conf`:

```
title   Arch Linux Multi-Kernel (PROJ-MK-ULTRA)
linux   /vmlinuz-7.0.0-mk2-g4bc24ec0b394
initrd  /initramfs-7.0.0-mk2-g4bc24ec0b394.img
options root=<YOUR-ROOT> rw intel_iommu=on iommu=pt movablecore=116G nouveau.config=NvGpuRm=1
```

Then rebuild the initramfs **at the installed path** (`mkinitcpio -P` does
not cover non-packaged kernels):

```bash
sudo mkinitcpio --kernel 7.0.0-mk2-g4bc24ec0b394 \
    -g /boot/initramfs-7.0.0-mk2-g4bc24ec0b394.img
```

Verify after reboot: `uname -r` contains `mk2`; `zgrep -E "^CONFIG_(MULTIKERNEL|OF)=" /proc/config.gz` both `=y`.

## Module signing note (honest scope)

Self-built kernels ship unsigned modules. `enforce-module-signing.sh`
probes for this and refuses `module.sig_enforce=1` if boot-critical modules
(nouveau) are unsigned — enforcing would break the next boot. Options:
(a) build with `CONFIG_MODULE_SIG_ALL=y` + `CONFIG_MODULE_SIG_KEY` pointing at
a generated key; (b) Secure Boot hosts: enroll via `mokutil --import` (MOK
trust chain); (c) leave `MODULE_SIGNING_ENFORCE=false` until (a)/(b) are done.
The trust chain (key → kernel) is what matters — a generated key alone
signs nothing the kernel will accept.

## Repo entry scripts (sequential)

`1_pre-install.sh` (repo root) → deps, clone/pin, fragment merge, build, install, boot entry, human checklist.
`2_setup.sh` (repo root) → the 8-phase wizard — run AFTER rebooting into the built kernel.
Optional build env: `MENUCONFIG=1` (manual config review before build).

## Upstream relationship

`multikernel/linux` is actively developed. The pin + fragment keep this repo
immune to upstream drift: rebase cadence is manual — re-pin, re-merge the
fragment, re-verify flags, rebuild. If a future requirement needs kernel
*source* changes, fork at that point (config-only needs never require it).
