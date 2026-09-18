# LAUNCH RUNBOOK — the complete operational cycle

This is the entire delivery as a runnable document. Every step, every expected
output, every decision point. Nothing referenced here lives outside this repo.

---

## 0. One-time state (reference build = 128GB i9-14900KF; derive YOUR values as marked)

| Item | State | Proof |
|---|---|---|
| Boot entry | `movablecore=116G` in the mk entry options line (no CMA needed — F-021: ACR_FLAGS_CMA selects isolation mode, not a region) | `2_setup.sh` syncs the mk entry from the conf automatically |
| Child size | reference build: `CHILD_MEMORY_SIZE="81917M"` — machine-derived, NEVER copy this to another box: run `sudo ./scripts/probe-pool-ceiling.sh` right after boot; the first SUCCESS is your ceiling. The kernel's own available-pool line (`exceeds available pool (0x...)`) is authoritative — the spawn's self-correcting retry uses it automatically | probe + reservation failure line |
| **Fork patch (REQUIRED for pools > ~64G)** | `arch/x86/include/asm/multikernel.h`: `MK_CTRL_PGTABLE_PAGES 64 → 256` — the identity page-table array held 64 entries (1 page-table page per GB at 2MB pages); 80G needs ~81. Without it every 80G baseline fails in `mk_arch_pool_chunk_added` → `mk_ident_map_range` and the kernel returns the claimed chunk (`pool: removed` follows the war). Kernel rebuild + initramfs regen + reboot required after the patch. | your `asm/multikernel.h` grep + the removed-81920 dmesg line |
| Baseline service | `active (exited)` at 39s, pre-session | your systemctl output |
| Pool boundary | CHILD_MEMORY_SIZE claimed from ZONE_MOVABLE (81917M reference) | `dmesg: Multikernel pool: added ... (<CHILD_MB> MB)` |
| Peripheral plan | GPU `01:00.0` (display handoff, default) + optional USB `00:14.0` (keyboard/mouse/SD — append for USB-root deployments) → child; NVMe + NIC → host | conf + guard checks |
| Conf | `etc/proj-mk-ultra.conf` carries the live deployment values (mask, devices as **by-id** paths — letter flips observed; run `useful-scripts/generate-config.sh` on a new machine) | grep outputs |
| Stock kernels | linux/lts/hardened untouched, taint=0 | your manual check |
| Host taint on mk kernel | 262144 = bit 18 `TAINT_TEST` (the fork's own module self-marks as test, kernel/module/main.c:2549) — documented exception; bits 12/13 on the HOST remain a hard violation | `grep -rn 'TAINT_' include/linux/panic.h` |
| SSH | enable before first boot cycle: `sudo systemctl enable --now sshd` — host control while the child owns USB | NIC stays on host by design |

## 1. The cycle (every launch — no reboot after the boundary boot)

```bash
cd ~/multikernel/proj-mk-ultra

# 1. Baseline (skips automatically when the pool is already populated)
sudo ./scripts/apply-baseline.sh
#   expect: "pool already populated" OR "baseline applied - pool holds <CHILD_MEMORY_SIZE> + <mask>"

# 2. Spawn — instance created from the pool
sudo ./scripts/spawn-child-instance.sh child-fsv
#   expect: ZONE_MOVABLE check green · APIC IDs 0x10..0x5E · passthrough clean
#           · drivers DEFERRED (keyboard stays live) · "Instance created"
#   USB note: keyboard/mouse/SD live until the boot step below - by design

# 3. Boot — peripherals hand off at this instant
sudo ./scripts/boot-instance.sh child-fsv
#   sequence inside: device-add overlay (documented format) → host driver
#   release → boot write → status poll → mktty console capture starts →
#   child taint assessed (nvidia → 12288 = design value)
#   FROM HERE: keyboard/mouse dark = THE CHILD OWNS THEM. Host = SSH only.
#   Child console streams to: /var/lib/proj-mk-ultra/watch/child-console-child-fsv.log

# 4. Validate
sudo ./scripts/first-spawn-validate.sh
#   FSV-2: creation PASS + runtime PASS when status=running
#   FSV-3/4: handoff evidence while the child runs
#   FSV-5: host taint bit-decomposed (18 = documented exception) + FSV-5b child
#          console taint (12288 = nvidia-open design)

# 5. Exit the child (from the child, or via SSH):
sudo ./scripts/boot-instance.sh --destroy child-fsv
#   graceful control shutdown → overlay-remove fallback → core hotplug-returns
#   handed-off slots (GPU/USB) → udev rebinds → devices RETURN AUTOMATICALLY. No replug.

# 6. Re-validate the halt semantics
sudo ./scripts/first-spawn-validate.sh
#   FSV-1 PASS: instances empty + uptime continuous = child halt, host survived
```

### 1b. Boundary troubleshooting chain (in order — each step names its resolution)

1. **Baseline war >5 min** (`activating (start)`, CPU climbing): the contig
   allocation is grinding. The kernel loops `start_isolate_page_range` →
   `set_migratetype_isolate` → `undo` every ~2min when pageblocks in the window
   fail isolation. Deadline rule: 20 minutes, then stop the service
   (`sudo systemctl stop mk-baseline.service`) and step to 2.
2. **CMA is NOT the lever** — source-verified (page_alloc.c:6991-7129): `ACR_FLAGS_CMA` selects the
   pageblock isolation mode only; no CMA region is consumed. The 80G claim
   succeeds at boot on `movablecore` alone once the fork constant below is
   patched. Skip to 3.
3. **Bisect the boot-time ceiling**: `sudo ./scripts/probe-pool-ceiling.sh 76 4`
   immediately after login (before the session fills memory). First SUCCESS =
   the stable boot-time ceiling → `CHILD_MEMORY_SIZE=<N>G` (keep movablecore
   at 116G — the zone that worked). One reboot, boundary lands.
4. **Kernel-change lever** (last resort, one-file patch on the desktop tree):
   `kernel/multikernel/contig.c` `mk_contig_try_zone` — target the CMA region
   explicitly instead of top-down scanning. Patch only after 2 and 3 prove
   the runtime allocator cannot converge.

## 2. Decision tree — boot-instance failure output

If the boot write is refused by every documented command, boot-instance prints
the instance's real file list + the last 8 kernel lines. That output names the
true control interface. Feed it back; one edit wires it. The handoff overlay
(device-add) has its own failure path with the kernel's exact objection.

## 3. Monitoring — no dead zones

- Host: resident watcher (`suspicious-watch.service`, 1% CPU/64M) + 5 monitors
  + journald — run continuously through the child's entire lifetime.
- Child: mktty console capture → `child-console-<name>.log` — the child's own
  ring buffer (taint, oops, module loads) lands in the host's watch directory.
- Both kernels' taint assessed: host bit-decomposed, child vs design value.

## 4. Teardown / rebuild

Every launch is ephemeral: destroy returns resources to the pool (they stay
claimed between launches — the next spawn draws from the pool without
re-running the baseline). The child root image on the SD persists; sessions
do not. Full wipe = partition-disk + install-child-kernel (destructive gates
demand explicit WIPE).

## 5. End-state: 4TB NVMe child data storage

The SD card is the interim child-data device. The target end-state: a dedicated
**4TB NVMe** for child user data — the SD model generalized, fully aligned to
the framework: device-level handoff (child-owned while running, returned on
exit), host inspection only between runs. Implementation notes:
- The 4TB drive is **separate hardware** from the host NVMe (host root never
  passes) — added to the handoff when installed via the instance device-add
  overlay (same mechanism as the PCI handoff), no identity-map impact (disks are
  devices, not pool memory — `MK_CTRL_PGTABLE_PAGES` is unaffected).
- The 81917M pool RAM stays the ephemeral runtime; the 4TB carries persistent
  user data across child rebuilds (the preserve-data flow generalized).
- No repo change until the drive is installed; the handoff path is already
  built and proven (device-add, hotplug return).

## 6. Next-phase entry points (named, one grep each — on the desktop tree)

- Child boot path internals (for ephemeral-ramdisk root): `grep -rn "mk_spawn" ~/multikernel/linux/kernel/multikernel/*.c | head`
- Instance devices at create-time (alternative to the move overlay): the `mk_dt_parse_devices` definition in dts.c
- By-id migration: set `CHILD_*_DEVICE` to `/dev/disk/by-id/usb-...` paths (spawn warns until you do)

## 6. Housekeeping awaiting your decision

- `rm` of the nine mk-susboot root strays + `etc/pool-donate.dts` (flagged in
  FINAL-REVIEW-9-9-ANTISLOP.md F-006/F-007 — not deleted per your rule)
- Ephemeral-ramdisk child mode: designed (pool + overlayfs, initramfs root,
  rebuilt each launch) — implementation starts with the mk_spawn read above
