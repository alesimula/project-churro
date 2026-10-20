# GBRUNCH vs Project Churro

Compared 2026-10-16 against [danbyumagic/gbrunch](https://github.com/danbyumagic/gbrunch) at
`a8936fd` (2026-10-12): its README/REPORT/AMD/VM docs, its compatibility-partition assets
(`dist/gbrunch-compatibility-assets-v7.tar.gz`: `init.gbrunch.rc`, fstab, manifests, GRUB config)
and its vendor-patch scripts — cross-checked against our image and the MSI logs. GBRUNCH is MIT
licensed (it bundles gbos-vm's MIT `erofs_metadata.py`), so code can be reused with its notice.
Churro has no LICENSE file yet; MIT would keep that simple.

## Same starting point, same walls

Both convert the same official image (Lenovo **ruby** recovery 16452207 / CL3B.260622.271.R1) on
the user's machine and redistribute nothing from Google. GBRUNCH independently confirms several
of our findings: the GFNI/AVX-VNNI CPU floor (they patched QEMU to emulate it), the dangerous
`spi-intel.writeable=1` in the vendor cmdline, the firmware updaters (fwupd, futility, gscutil…),
missing Meteor Lake GPU firmware, the 4 GiB userdata filling up on first boot (system_server crash
loop, same as our RescueParty run), and FAT log files ending up empty (their first logs were
0-byte files; our fixed-size files fixed the same problem).
New detail from them: first boot copies **49 AICore model preloads (4.28 GB)** plus app odex from
`system_b` into userdata (`cppreopts`) — that alone exceeds the image's 4 GiB.

## Approach in one table

| | GBRUNCH | Churro |
|---|---|---|
| Kernel | Google's, untouched | rebuilt from the exact same source/config/toolchain, identical export CRCs (kABI check 0/4501), so Google's modules still load *and* we can add drivers |
| Google partitions | byte-identical, dm-verity **enforced** | vendor/system_ext/product repacked (labels kept), verity off |
| Compatibility layer | own ext4 `/oem` partition + separate derived vendor partition | features repack the vendor EROFS; packs + logger in our ramdisk |
| Disabling Google services | `androidboot.init_rc=/oem/init.gbrunch.rc`: replaces the top-level init.rc and imports an **allowlist** of service files (28 left out) | delete/stub files in vendor, blacklist kernel drivers |
| Kernel cmdline | built from scratch (allowlist) | Google's, filtered (blocklist) |
| Security HALs | Cuttlefish nonsecure KeyMint/Gatekeeper on `/oem` | AOSP software KeyMint + non-secure Gatekeeper (both from the emulator image) |
| Userdata | **unencrypted** (fstab override drops fileencryption) | metadata encryption kept |
| Boot control | AOSP default boot HAL (no firmware calls) | Google's HAL + no-op `crossystem` stub |
| Logs | Android shell service snapshots logcat to a FAT partition every 10 s | static rdinit logger: kmsg + logcat (logd socket) from the first second, crash-safe fixed-size files, readable in Windows; on-screen console, earlycon entry |
| Firmware | hand-picked per device (MTL GPU, AX211 + PNVM, BT, regulatory.db) | `firmware-extra`: everything the image's modules declare (151 files), automatically |
| Graphics | Google's stack only; QEMU via Cuttlefish SwiftShader | Google's stack + our Mesa build (iris/radeonsi/virgl/llvmpipe), GRUB-switchable; ARL allocator work, safe-display entry, framebuffer handover patches |
| Hardware scope | GRUB **refuses** non-HP/QEMU machines unless an "experimental" entry is picked | generic: any Intel Gen12+ PC |
| Deliverable | Debian live "Toolbox" ISO (64 GB USB) that downloads, builds, trials and installs | one `churro.sh auto` on Linux/WSL → `.img` for Etcher (32 GB stick) |
| Install | guarded internal dual-boot installer (QEMU-tested, not on hardware) | `churro.sh install` (simple, whole disk) |
| Proven hardware | HP Envy x360 / Meteor Lake 155U (`7d45`, natively in minigbm) | MSI / Arrow Lake 255HX + NVIDIA hybrid |
| Tooling | ~11,000 lines of Python in `tools/` alone, many QEMU guard tests, macOS flows | ~1,600 lines total: bash, 2 small C programs, one 100-line Python helper (`lpinfo.py`) |

## What Churro does better

- **Rebuilding the kernel with identical kABI.** With Google's kernel, GBRUNCH can only add
  modules that use the 4,501 symbols it exports (amdgpu needs 131 more; our out-of-tree i915 needed
  137), and built-in-only options (SYSFB/simpledrm, `PINCTRL_AMD`) are impossible. Its AMD attempt therefore
  builds a different kernel (new identity, protected exports cleared) that leaves 470 of Google's
  modules unmatched. Our route keeps every Google module and adds simpledrm/fbcon, AHCI, eMMC,
  virtio, ath9k, and can add amdgpu/VMD/pinctrl the same way.
- **Generic by default**: no per-model gate, firmware chosen from module metadata, GPU stack
  switchable at boot, hybrid/multi-GPU fixes (boot framebuffer removal) that a single-laptop
  project never meets.
- **Earlier, sturdier logs**: kernel log from the first second, logcat straight from logd, files
  that survive power cuts, readable in Windows; plus visible on-screen debugging.
- **Simpler to run and maintain**: one command, dependencies auto-installed, a single image file.
- **Encryption kept** on /data.

## What GBRUNCH does better

- **Google's bytes untouched + verity on**, with all changes on a separate partition — cleaner for
  importing a new recovery later, and nothing to repack for disabling services (init_rc allowlist).
- **Safety details we lacked**: `efi_pstore.pstore_disable=1`, an fstab without `voldmanaged`
  entries, Google's OTA updater disabled, board tuning (`init.ruby.rc`) never loaded — see below.
- **Wi-Fi completeness**: PNVM companion files and an upstream regulatory.db + signature.
- **Display colour**: forces SDR (`vendor.hwc.drm.force_color_mode=7`, `persistent_hdr=false`,
  `use_log_gamma_lut=false`) — Google's defaults (BT.2020, HDR, log gamma) made their panel
  look washed out.
- **Process**: automatic recovery download from Google's catalog with pinned hashes, a hardware
  inventory boot before trying Android, an installer with GPT backups/readback/rollback, extensive
  QEMU tests, a software-rendered QEMU profile that reaches the setup screen.

## Fixed in Churro because of this comparison

1. **efi_pstore** (safety): our kernel registered `efi_pstore`, i.e. kernel panics were saved into
   the PC's UEFI NVRAM (and the debug entries turn init crashes into panics). Filling NVRAM can
   stop some firmwares from booting. Now `efi_pstore.pstore_disable=1` is always on the cmdline.
2. **Lenovo board tuning** (generic correctness): `init.ruby.rc` writes the Lenovo laptop's RAPL
   limits (PL1 18 W, PL2 35 W, PL4 150 W) and a TCC offset to whatever CPU it runs on. The MSI log
   shows PL1/PL2 accepted — the 255HX (55 W class) ran heavily throttled. `firmware-lockdown` now
   removes those writes from every vendor rc file.
3. **Lost SELinux label** (found while doing 2.): `gfx-mesa` edited `/vendor/build.prop` with
   `sed -i`, which drops xattrs on a non-SELinux host — the built image had it without an SELinux
   label. Android still read it, but both scripts now edit in place (verified: label kept).

## Open safety items (next, in this order)

1. **Android's storage manager can see PC disks.** The vendor fstab has
   `voldmanaged` wildcards for `/devices/*/nvme/nvme[1-9]*` (any second NVMe), `/devices/*/mmc_host*`
   (SD readers *and* internal eMMC, e.g. the T300FA's Windows disk) and `/devices/*/usb*`. Android
   would mount FAT partitions read-write and can offer to "set up/format" a disk it doesn't
   understand — on a PC that can be Windows. Already seen: it mounted our own boot stick's
   CHURRO-LOG as "USB storage". The MSI is safe only by accident: its NVMe is behind Intel VMD
   (`RstVmd` ACPI tables) and Google's kernel has no VMD driver, so the disk is invisible.
   **Done:** `firmware-lockdown` drops the `nvme` and `mmc_host` lines (`usb` stays; excluding the
   boot stick itself is still open), and `VMD` is now a `storage`-pack module (install on VMD
   laptops like the MSI).
2. **Google's OTA updater.** `update_engine`/`update_verifier` still run. Once a signed-in install
   gets an update offer it would download GBs into userdata (and Virtual A/B snapshots use /data
   too) for a slot our GRUB never boots. GBRUNCH doesn't start them; we should do the same.

Checked in our logs and *not* a problem for us (GBRUNCH had to fix them): the Weaver watchdog
kill (our `security-software` already hides it) and graphics-allocator memfd SELinux denials
(none: no need for their 82-domain policy patch).

## Worth reusing (ranked by value/effort)

| Idea | Effort | Notes |
|---|---|---|
| fstab override without `voldmanaged` nvme/mmc | small | open safety item 1 |
| Disable `update_engine` + `update_verifier` | small | open safety item 2 |
| Wi-Fi PNVM + upstream `regulatory.db`/`.p7s` in `firmware-extra` | small | our log: "regulatory.db is malformed or signature is missing" → world-roaming channels; PNVM files aren't declared by modinfo, so add every `iwlwifi-*.pnvm` matching a requested ucode family |
| SDR display props | tiny | only if colours look washed out on the MSI — ask first |
| Hardware inventory into CHURRO-LOG | small | the debug logger could also save PCI/USB/ACPI modaliases + bound drivers: exactly what's needed to add drivers for unknown laptops (e.g. the missing touchpad pinctrl) |
| CPU preflight message | small | old CPUs crash silently in init (GFNI); a check before `/init` could print "this CPU is too old" on our console |
| Recovery auto-download | small | Google's catalog `https://dl.google.com/dl/edgedl/device/recovery/production_recovery.json` lists ruby, lapis (ASUS) and moonstone (Acer), all x86, same build; `churro.sh` could fetch + verify (MD5 in catalog, SHA-256 pinned) when no `.bin` is given |
| Optional "skip AICore preloads" | small | saves ~4.3 GB of userdata for small sticks (AI features then download/unavailable) |
| AOSP default boot HAL instead of the crossystem stub | medium | cleaner; GBRUNCH notes it must start before vold's checkpoint step |
| init_rc allowlist + separate compatibility partition | large | the way to keep Google's bytes and verity, and to import new recoveries; brittle per build (hard-coded list) — a design option for a later "update" story, not now |
| Installer guard design | medium | GPT backup/readback/rollback, never shrink NTFS, append to BootOrder — for when `install` targets disks with Windows |
| QEMU software profile | medium | SwiftShader (`vulkan.pastel`) + `debug.hwui.renderer=skiagl` + `service.sf.prime_shader_cache=0` reached "Hi there"; our Mesa llvmpipe "soft" mode covers the same need |
| AMD notes | — | `DRM_AMD_DC`, `PINCTRL_AMD`, `X86_AMD_PLATFORM_DEVICE` are bool (must be `=y`) — fine for our kernel route as long as the kABI check stays at 0; stock minigbm has no amdgpu backend (matches our generic-allocator plan) |

## Not taken (doesn't fit Churro's goals)

- Per-model GRUB gate (SMBIOS): contradicts "as many devices as possible"; a warning is enough.
- Debian live toolbox, macOS flows, ~11k lines of Python: heavy to maintain; the user prefers
  little or no Python. Revisit only if non-Linux users become the main audience.
- Unencrypted userdata; hand-picked per-device firmware (our modinfo-driven list scales better).

Updates/OTA (neither project supports them; what a no-system-edit Churro would need): see [07-updates.md](07-updates.md).
