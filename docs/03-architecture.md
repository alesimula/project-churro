# 03 — Churro architecture (how the conversion works)

Goal: take Google's signed Googlebook recovery image and turn it, locally, into something that
boots and installs on generic x86_64 UEFI PCs. Nothing Google-owned is redistributed; every extra
component is either built from public source or downloaded from Google's public servers by the
script (same model as Croissant downloading ChromeOS recovery images).

## Layers

```
 recovery.bin (Google)                       Churro adds
 ┌────────────────────────────┐
 │ EFI-SYSTEM (empty)          │ ◄── GRUB + kernel + initrd + grub.cfg/env.cfg   (lib/esp.sh)
 │ boot_a      GKI kernel      │ ──► reused, or replaced by a Churro kernel        (kmod/)
 │ vendor_boot_a ramdisks+cmd  │ ──► reused + Churro ramdisk (module packs) + bootconfig
 │ init_boot_a generic ramdisk │ ──► reused
 │ vbmeta_a                    │ ──► flags=3 (verity off) when partitions are patched
 │ super: system/vendor/...    │ ──► EROFS repack of vendor_dlkm / vendor / system_ext by "features"
 │ userdata, metadata, misc …  │ ──► untouched (installer will reformat)
 └────────────────────────────┘
```

### 1. Bootloader replacement (always)
Googlebooks boot via coreboot/depthcharge; a PC has UEFI. Churro builds one initrd exactly like a
boot-image-v4 bootloader would (vendor ramdisk → dlkm ramdisk → generic ramdisk → extras →
bootconfig trailer) and boots the kernel's EFI stub through GRUB. GRUB passes the dynamic bits on
the kernel cmdline: `androidboot.boot_part_uuid` (lets first-stage init find `super` on whatever
disk we booted from) and `androidboot.boot_source=external|internal`.

### 2. Kernel: stock GKI or Churro kernel
* **Stock GKI** (`boot_a`): fine for Intel Gen12+ (the image's own xe/iwlwifi/SOF modules) and for
  VMs (virtio module pack from Google's matching `kernel_virt_x86_64` CI build).
* **Churro kernel** (`kmod/build-kernel.sh`): *the same source commit and config* (from Google's
  public GKI build manifest + the image's IKCONFIG), built with the exact toolchain (clang
  r584948c, Android rustc 1.91.1, bindgen 0.72.1, pahole 1.31), same release string, kABI-stable
  CRCs — so the image's prebuilt vendor/system modules still load — but **without KMI symbol
  trimming** and with extra drivers (`kmod/profiles/*.conf`): i915 for older Intel, simpledrm on
  the UEFI framebuffer for *any* GPU, AHCI/SATA, eMMC (sdhci-pci/acpi), virtio-gpu, fbcon, ath9k.
  Needed because the stock GKI exports only the KMI symbol list (an out-of-tree i915 build had 137
  unresolved symbols). It also trusts Google's GKI module signing cert (extracted from the image's
  vmlinux) so system_dlkm modules keep their "signed" status. `prepare.sh` refuses the kernel if
  any of the 4501 GKI export CRCs differs from Google's `vmlinux.symvers`.
  **Distro module set** (profile `DISTRO_*`): every option a pinned Arch Linux kernel config
  builds as a module, if its Kconfig lives in a consumer-PC driver directory and it isn't denied
  (~3900 options → ~3000 extra modules, installed by `drivers-extra`). Modules only: built-in
  options are never weakened, and options a module would switch on that core headers test
  (struct fields in netdevice.h, i2c.h, sched.h, …; they'd change hundreds of GKI CRCs) are kept
  off by leaving out whatever selects them (select chains followed automatically: e.g. iavf →
  NET_SHAPER, two I2C bus drivers → I2C_SLAVE).
  Small built-in source fixes live in `kmod/patches/*.patch` (applied copies recorded in
  `<src>/.churro-applied`, edited/removed patches reversed automatically; the kernel cache dir is
  keyed on profile + patches + build script):
  - `drm-remove-firmware-fb` — DRM core removes the firmware framebuffer (simpledrm) when any PCI
    display driver registers. Google's prebuilt xe never does it (no EFI framebuffer on
    Googlebooks), so simpledrm stayed and hwcomposer used it as the primary display (black screen).
    Side effect: xe has no fbdev, so the on-screen debug log stops when xe loads (~5 s); the
    CHURRO-LOG files are unaffected. The GPU then reuses simpledrm's `card0`, which needs
    ueventd's parallel main loop off (gfx-mesa): otherwise simpledrm's late "remove" can delete
    the new `/dev/dri/card0` and the composer boots headless.
  - `sysfb-disable-any-gpu` — also drop it when the framebuffer belongs to *another* GPU
    (hybrid laptops with the boot framebuffer on an undriven dGPU).
  - `nouveau-hybrid-guard` — nouveau binds only if no other display controller exists
    (discrete-only laptops, desktops without iGPU); hybrid machines keep their iGPU stack.
    `nouveau.hybrid=1` overrides.
  - `nouveau-dsc-off` — turns off DSC the firmware left enabled (head + panel); nouveau
    never compresses, so an inherited DSC state garbles the picture or stalls the display.
  - `vt-no-ctrl-alt-del` — the VT keyboard handler (comes with fbcon) hard-reset the machine on
    Ctrl+Alt+Del (no shutdown, no sync); now it only signals init, which ignores it.
  - `nouveau-up-01..09` — mainline GB20x / GSP-RM 570 display fixes, unchanged (r570
    `DP_CONFIG_STREAM` size, GB20x head state, vblank vector, HDMI packets; with prerequisites).

  **When the kernel source changes** (a newer Googlebook image = newer GKI commit, or newer
  nouveau backported): every patch is re-applied by `build-kernel.sh`, and a patch that doesn't
  apply stops the build — on purpose, nothing is kept blindly. For each failing patch:
  - `nouveau-up-*`: copies of mainline commits (the `From <sha>` header names the commit). If the
    new source already contains that commit, delete the patch; otherwise rebase it.
  - `nouveau-dsc-off`: needed until nouveau itself turns off (or supports) DSC. Check the new
    source: if `headc57d_mode()`/`headca7d_mode()` (or nouveau generally) now program
    `HEAD_SET_DSC_CONTROL`, drop the patch. If not, rebase it, and **extend it to every new display
    class**: a new GPU generation brings a new `dispnv50/head<class>.c` (e.g. `headca7d.c` came with
    GB20x); add the same DSC_CONTROL/DSC_PPS_CONTROL = 0 writes to its `*_mode()` and the two method
    defines to its class header, with offsets/head stride from NVIDIA's published
    `cl<class>.h` (open-gpu-kernel-modules, `src/common/sdk/nvidia/inc/class/`). The sink half
    (`DP_DSC_ENABLE` in `nouveau_dp.c`) is GPU-independent. Without it, laptops whose firmware
    enables DSC (high-refresh panels) show a squeezed, noisy strip (docs/02).
  - the others (`drm-remove-firmware-fb`, `sysfb-disable-any-gpu`, `nouveau-hybrid-guard`,
    `vt-no-ctrl-alt-del`): Churro behaviour, not upstream fixes — rebase them, their header says
    why they exist.

### 3. Module packs (`--modules dir`)
Directory of `.ko` + `modules.load` (+ `modules.dep`). Added to the first-stage ramdisk, loaded
by Android's first-stage init before `super` is mounted (storage/GPU drivers). Made with
`tools/make-pack.sh` (dependency closure) or `tools/fetch-virt-pack.sh`. `prepare.sh` makes
`virt`, `gpu`, `storage` (default) and `wifi` (opt-in, `auto --packs virt,gpu,storage,wifi`).
First stage can't read `/vendor/firmware`, so packs hold only drivers that need no firmware.

### 4. Features (`--features a,b`)
`features/<name>/` may contain `<partition>/…` (files overlaid into that EROFS partition),
`patch-<partition>.sh` (scripted edits on the extracted tree) and `bootconfig` (extra lines).
SELinux labels are kept from the original image (extracted with `fsck.erofs --xattrs`) and new
files get a sibling's label or an explicit one.

* `security-software` (default) — replaces the Googlebook security stack (Trusty VM on x86 pKVM
  + pvmfw DICE + GSC/Ti50) with Android's software implementations: AOSP's software KeyMint
  (from Google's public Android 17 emulator image) as `android.hardware.security.keymint-service`
  (a name Googlebook's sepolicy already labels `hal_keymint_default_exec`), AOSP's non-secure
  Gatekeeper (from the emulator's `com.android.hardware.gatekeeper.nonsecure` APEX) as
  `/vendor/bin/hw/android.hardware.gatekeeper-service` (labelled `hal_gatekeeper_default_exec`;
  this gatekeeperd has no software fallback: without a HAL no lock-screen PIN/password can be
  set), Trusty/GSC HALs and VINTF entries removed, gscd disabled. Also removed because they only
  fail and restart all session: the Trusty security VM launchers (system_ext), the Pixel face HAL
  APEX, the EC charge-control HAL.
  → the Churro counterpart of Croissant's swtpm.
* `security-trusty-vm` (experimental) — keep Trusty, run the security VM non-protected or
  protected (`androidboot.churro.security_vm=`). Only useful on hardware where x86 pKVM works;
  the KeyMint TA still needs a DICE chain + GSC.
* `firmware-lockdown` (default, **safety-critical — never drop it for a PC build**) — Googlebooks
  update their own firmware from Android automatically and without asking. Removed: `flashrom`,
  `futility`, `vpd`, `fwtool`, `elogtool` + the futility executor HAL (the VPD executor stays,
  toothless without `vpd`: system_server blocks on it and would be killed); `crossystem` becomes a
  no-op stub that accepts writes without touching anything (the boot-control HAL's
  markBootSuccessful needs `crossystem fw_result=success` to succeed, else "Checkpoint commit
  failed" reboots every boot), and
  `fwupd` + its boot-time blocking update script + cabinets (it runs at *every* boot with
  `ApprovalRequired=false` against the public LVFS and Googlebook peripheral cabinets: on a PC it
  could reflash SSDs, USB hubs, cameras, docks, Thunderbolt controllers). Independently,
  `churro.sh` always strips `spi-intel.writeable=1` / `ignore_protection_status=1` and blacklists
  the SPI flash drivers (`spi_intel`, `spi_intel_pci`) and the TPM drivers (`tpm`, `tpm_tis*`,
  `tpm_crb`): the image's `gscutil` and `check_tpm_clear` send Google-security-chip commands to
  `/dev/tpm0` at every boot, and on a PC that is the TPM Windows/BitLocker depends on. It also
  adds `efi_pstore.pstore_disable=1` (no kernel crash dumps into the PC's UEFI NVRAM) and
  `iommu.passthrough=1` (not a lockdown: Google's iwlmvm Wi-Fi driver breaks on a translating IOMMU,
  docs/05 "Other hardware"; firmware-marked external ports stay translated), and the
  feature strips board tuning from the vendor rc files (`init.ruby.rc` writes the Lenovo
  laptop's RAPL power limits and a TCC offset to whatever CPU it runs on).
  There is deliberately no switch to turn any of this back on.
* `drivers-extra` (default) — distro-like driver coverage: every module of our kernel build the
  image doesn't have (the profile's distro module set, nouveau, …; ~3000) goes into vendor_dlkm,
  where ueventd loads modules by device alias, so a machine only loads what matches its hardware.
  ABI gate: `depmod -e -E Module.symvers` over the image's modules (vendor_dlkm + system_dlkm) +
  ours; a module with an unknown symbol or a CRC mismatch against Google's modules is left out
  (with everything that needs it), and a Google module is replaced by our build only if ours
  exports everything Google's does with identical CRCs (drm_ttm_helper: + the fbdev console).
  `skip.txt`: modules never added. i915 is added, but its aliases lose every device ID the
  image's `xe.ko` binds, so `ueventd` only loads it on pre-Gen12 Intel GPUs.
* `firmware-extra` (default) — firmware the image's drivers need but the image lacks, installed
  into `/vendor/firmware` (labelled like that dir) from a pinned linux-firmware release
  (`CHURRO_LINUX_FIRMWARE`; tarball downloaded and unpacked once into
  `$CHURRO_CACHE/linux-firmware-<tag>`): names every vendor_dlkm/system_dlkm module declares
  (`modinfo -F firmware`), every file WHENCE lists under a shipped driver (catches names drivers
  build at runtime: board files, per-laptop amplifier tunings), and `extra.txt`. Plus two things
  outside linux-firmware: Intel's audio DSP firmware/topologies (sof-bin release, `CHURRO_SOF`)
  and the Wi-Fi regulatory database (wireless-regdb, `CHURRO_REGDB`). Patch scripts get
  `CHURRO_SUPER`/`CHURRO_HERE`/`EROFS_BIN` so they can read other LP partitions. Names
  linux-firmware only creates when installed (WHENCE `Link:`) are resolved and become hardlinks to
  one copy; `skip.txt` lists globs never installed (NVIDIA GSP 535). vendor_dlkm is repacked
  before vendor, so modules drivers-extra adds get their firmware too. sof-bin is merged file by
  file without overwriting: the image already ships some of its dirs (`intel/sof-ipc4/ptl`), and
  skipping existing dirs whole had left out every other platform (Arrow Lake's `arl-s` too).
* `audio-generic` (default) — built-in audio on PCs. Google's audio HAL (`dras`, in the APEX
  `com.android.hardware.audio.desktop`) takes its card ID and config dir from Google's hardware
  mapping table (`/vendor/etc/hardware_descriptor/mapping_table.binpb`, key `audio-config-dir`),
  whose default is Lenovo's board: dir `/vendor/etc/audio/sof-rt5682_alc5682ivs_tas2563`, card
  `hw:sofrt5682`. No PC has that card: after 10 s the HAL starts a stub ("Primary module audio will
  not work"; USB/Bluetooth audio still work). `vendor.audio.soundcard.name` does not change that
  (tried). The feature adds generic configs per ALSA card ID in `/vendor/etc/audio/<id>` (`PCH`,
  `Intel`, `Generic`, `Generic_1`: legacy HD audio; `sofhdadsp`: SOF's generic HDA machine):
  speaker and headphones on PCM 0 (the kernel's HDA auto-mute switches the outputs; the
  Headphone/Mic nodes name the jacks' input devices, `<card name> Headphone`/`Mic`, so Android
  sees plugging), internal mic; HDMI nodes only in a `<id>_hdmi` variant, chosen when the card has
  `pcmC<n>D3p` (on hybrid laptops HDMI audio is on the dGPU's card; an HDMI node pointing at a
  missing PCM made Android route to nothing). `/vendor/bin/churro-mixer` (static C, ~50 lines)
  unmutes the card before the HAL starts, like `alsactl init`: the kernel creates HD-audio's
  `Master` muted at volume 0 and leaves that to userspace; every `Playback Switch`/`Capture
  Switch` on, `Master Playback Volume` to its own maximum (fixed values in `mixer_paths.xml` don't
  work: libaudioroute wants one value per channel, and channels/ranges differ per codec). All
  addressed as the board's card ID; same fields as Google's file
  (`DSPLatency`, mic channel map/sensitivity: without them the HAL fails "to create internal
  card") plus Google's neutral `dsp.ini` and volume curves. Verified in QEMU (intel-hda: card
  created, PCM playback reaches QEMU's audio backend). At boot `/vendor/bin/get_variant_audio`
  (a name Google's policy already gives a domain that reads sysfs and sets `vendor.audio.*`; Google
  ships no such script) waits up to 15 s for a card with a config (non-HDMI codec, so AMD's
  HDMI-only "Generic" card is skipped) and sets `vendor.audio.churro.card` + `.index`;
  `churro-audio.rc` (one literal trigger per card ID / index: init expands `${...}` in vendor rc
  files as `vendor_init`, which can't read these properties) bind-mounts the config over the board
  dir, renames the card to the board's ID (`write /sys/class/sound/cardN/id sofrt5682`, ALSA
  allows renaming) and restarts the HAL. Unknown cards (SoundWire laptops, machine-specific SOF
  cards) keep Google's config: add a `mk` line in `patch-vendor.sh`.
  Related, in `churro.sh` (always): the vendor cmdline's audio settings are stripped
  (`snd_intel_dspcfg.dsp_driver=3` forced SOF on every Intel HD-audio controller, so
  `snd_hda_intel` never bound; plus `snd_sof_pci.ipc_type=1`, the board's
  `snd_intel_sdw_acpi.sdw_link_mask`, `sof_use_tplg_nhlt=1`): the kernel then picks SOF or
  legacy HDA per machine, like a distro. And `patch-vendor_dlkm.sh` removes two board lines from
  the module config: `blocklist snd_hda_intel` (`modules.blocklist`) and
  `options snd_sof_intel_hda_generic hda_model=alc-2024y-chromebook dmic_num=4` (`modules.options`:
  Lenovo's codec pin quirk and DMIC count, wrong on any other machine), and softdeps every
  `snd-hda-codec-*` driver before `snd_hda_intel` / `snd_sof_intel_hda(_generic)`: the controller
  binds a driver to each codec right after finding it and gives up without one ("Cannot probe
  codecs"); Linux autoloads them via `request_module`, Android can't (Google softdeps its one codec).
* `gfx-minigbm` (default) — the graphics buffer allocator libraries (`libminigbm_gralloc.so`,
  `libgbm.so`) rebuilt from AOSP `external/minigbm` (android17-release, the source of Google's
  own build) by `gfx/build-minigbm.sh` with the NDK, plus `gfx/minigbm-patches/`. Google's build
  rejects every GPU missing from its ID tables; ours asks the xe kernel driver for the GPU's
  graphics IP version instead (any Intel Xe GPU works), and on nouveau allocates real buffers
  (`NOUVEAU_GEM_NEW`, VRAM) instead of dumb buffers, which render nodes refuse. Google's allocator service, mapper and
  gralloc0 module stay and load our libraries: they're linked against the image's own libc++
  (platform `std::__1` ABI) and the build refuses to install them unless every symbol the image's
  binaries take from Google's versions is present. Written in place (labels kept).
* `crypto-generic` (default) — BoringSSL (`libcrypto.so`, `libssl.so` in `/system/lib64` and
  `/vendor/lib64`) rebuilt by `crypto/build-boringssl.sh` from the upstream commit the image's
  exports pin, with Android's build options but `-march=x86-64-v3` instead of `pantherlake`, so
  its CPUID dispatch works on Haswell+ (docs/05, "BoringSSL rebuilt"). Needs the NDK (from
  `prepare.sh`) and downloads the source + a pinned Go (checksummed; only runs the FIPS hash
  injector). libc++ is static and hidden, compiled in the platform `std::__1` namespace because
  libcrypto exports two C++ helpers taking `std::atomic`. The build stops unless both libraries
  export every dynamic symbol the image's do (same type, binding, data size; extras are allowed
  and counted, so a newer `BORINGSSL_REV` in `versions.env` can pass — layouts aren't checked). System is the first feature partition mounted at
  `/` (`patch-system.sh`, files under `system/`). New recovery image: the gate tells whether
  `REV` still matches. The 11 APEX copies of the same libraries (Conscrypt, Tethering, Wi-Fi,
  Bluetooth, ...) are meant to be covered by bind mounts at boot (`churro-apex-crypto.rc`), not
  by repacking the signed APEXes — not working yet: SELinux denies init `mounton` on those files. Not covered: Tethering's `libcrypto_httpengine.so` (Cronet's own BoringSSL).
* NPU: `intel_vpu` is blacklisted unless `CHURRO_NPU=true` (top of `churro.sh`): the image only
  has Panther Lake NPU firmware and on Arrow Lake the failed probe froze the machine.
* `debug-log` (default) — boot log to a file you can read from Windows. The "debug" GRUB entries
  start `/churro/logger` (static, `features/debug-log/logger.c`) as `rdinit`: it forks a child
  (own mount namespace, invisible to first-stage init) that copies `/dev/kmsg` — kernel + Android
  init messages — into `boot.log` on the **CHURRO-LOG** partition (the unused KERN-A slot turned
  into a FAT32 basic-data partition; the ESP is hidden by Windows), fsync'ed per batch so a hang
  + power button keeps it; then execs the real `/init`. `boot.log`/`boot.prev.log` are created
  by the build at 64 MiB, filled with blank lines, and only overwritten in place (text ends at the
  first empty line; rotation copies in place too), so FAT and directory entries never change at
  boot — appending had left the FAT inconsistent after a power cut on a real stick. Full file →
  the logger writes a "full" note and stops (a normal boot is ~1–3 MiB). A second child streams
  Android's log into `logcat.log` the way logcat does: it connects to logd's reader socket
  (`/dev/socket/logdr`, reached via `/proc/1/root` because the logger lives in its own mount
  namespace), sends `stream lids=0,1,3,4` (main, radio, system, crash) with a 16 MiB receive
  buffer (logd drops slow readers), and writes `HH:MM:SS.mmm pid tid P tag: msg` lines (UTC). The child stays in the `kernel` SELinux
  domain, so the feature adds the needed rules to the vendor policy and drops the precompiled
  policy (init compiles it at boot). Feature hooks used: `build-ramdisk.sh`, `cmdline-debug`.
* `gpu-nouveau` (default) — NVIDIA GPUs (nouveau.ko itself comes with drivers-extra):
  `nouveau.atomic=1` for drm_hwcomposer, and wildcard SELinux labels so apps can read any GPU's
  PCI ID files (Mesa's device enumeration). Details: docs/05.
* `gfx-mesa` (default) — Mesa built with the NDK (`gfx/build-mesa.sh`: iris/crocus/nouveau/zink/
  virgl/softpipe + NVK, hasvk/radv on request) and the boot-time stack selection
  (`androidboot.churro.gfx`, set by GRUB from PCI: native / nouveau / mesa / soft).

### 5. Installer
The recovery image already has the installed layout, so `churro.sh install <img> <disk>` (from
any Linux live) writes the image, moves the backup GPT to the disk end, grows userdata over the
free space and sets `boot_source=internal` on the ESP. TODO: an installer inside the booted image.

## Updating the driver set and firmware (checklist, no prior context needed)

What it is: the Churro kernel is Google's GKI rebuilt from source (§2). On top of the GKI config
it builds, as modules, the driver part of a Linux distro's config ("distro module set"), and the
build installs those modules plus their firmware into the image. Everything is pinned, so an
update means bumping pins, rebuilding and reading what the build reports. Nothing is downloaded
unpinned.

Files involved (each has comments explaining the why):
| File | Role |
|---|---|
| `versions.env` | every pinned version: Arch config tag, linux-firmware, sof-bin, wireless-regdb, Mesa/libdrm/NDK, emulator image, BoringSSL + Go, erofs-utils |
| `kmod/profiles/generic.conf` | `DISTRO_CONFIG` (URL of the pinned distro config, tag from `versions.env`), `DISTRO_DIRS` (regex: Kconfig file locations whose modules are taken), `DISTRO_DENY` (regex: symbols never taken), optional `DISTRO_BUILTIN_OK` (space-separated core options checked to be harmless) |
| `kmod/build-kernel.sh` | the `if [ -n "${DISTRO_CONFIG:-}" ]` block: picks the symbols, adds them as `=m`, keeps core-struct options off (follows `select`/`imply` chains), refuses to weaken built-ins |
| `tools/prepare.sh` | kABI check after the build: all GKI export CRCs must equal Google's `vmlinux.symvers`, else the kernel is rejected; copies `Module.symvers` into the kernel cache dir |
| `features/drivers-extra/patch-vendor_dlkm.sh` (+ `skip.txt`) | installs every module of our build that the image lacks into vendor_dlkm, after a `depmod -e -E` ABI check against the image's own modules; prints what it left out and why |
| `features/firmware-extra/patch-vendor.sh` (+ `skip.txt`, `extra.txt`) | firmware for all shipped modules: pinned linux-firmware release (`CHURRO_LINUX_FIRMWARE`), sof-bin (`CHURRO_SOF`), wireless-regdb (`CHURRO_REGDB`) |

Steps:
1. Find the image's kernel version: the kernel release string printed by `prepare.sh`
   (e.g. `6.18.21-android17-…`), or `kernel.release` in the kernel cache dir.
2. Distro config: pick a config for the **same major.minor kernel version** (a newer series has
   different Kconfig symbols). Arch Linux keeps one per release tag:
   `https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/raw/<tag>/config`, tags
   look like `6.18.9.arch1-1` (list them on that repo's tags page; not every point release has
   one). Put the tag in `ARCH_LINUX_CONFIG_TAG` (`versions.env`). Any distro's full kernel
   config works the same way (Debian/Fedora), as long as the version matches: then change the
   `DISTRO_CONFIG` URL in the profile.
3. Firmware pins (`versions.env`, "Firmware" section, or override with the env vars):
   linux-firmware = a release tag present on
   `https://cdn.kernel.org/pub/linux/kernel/firmware/` (`linux-firmware-<YYYYMMDD>.tar.xz`);
   sof-bin = a release of `github.com/thesofproject/sof-bin` (version without the `v`);
   wireless-regdb = a `master-YYYY-MM-DD` tag of `git.kernel.org/…/wens/wireless-regdb.git`.
4. Rebuild: `sudo ./churro.sh auto <recovery.bin> <out.img>` (Linux or WSL, as root). Changing the
   profile changes the kernel cache key, so the kernel is rebuilt (incremental when the build
   tree in `$CHURRO_CACHE/src-<build>/common/out-kernel-generic` still exists).
5. If the build stops, the message says why:
   - `distro modules: can't tell which module enables X` → a new module turns on core option X
     (one tested in core headers, so it would change GKI struct layouts) other than through
     `select`. Find the module(s) whose Kconfig depends on/defaults X and add them to
     `DISTRO_DENY`; or, if X only changes function declarations and no struct (read the
     `#ifdef CONFIG_X` sites in `include/`), add X to `DISTRO_BUILTIN_OK`.
   - `distro modules would weaken built-in options` → a taken module lowers a built-in (`=y`)
     option to `=m` (listed). Find the taken symbol it depends on and add that to `DISTRO_DENY`.
   - `kABI broken … CRC differs: <symbol>` → some built-in option still changed a GKI type. Diff
     `.config.predistro` against `.config` in the kernel build dir (non-`=m` lines), find the new
     `=y` options tested in `include/` (`grep -rlw CONFIG_X include/`), deny what enables them.
     Never "fix" it by accepting different CRCs: Google's prebuilt modules would stop loading.
6. Read the build log: `drivers-extra` prints how many modules it added and every module it left
   out (`needs unknown symbol` / `disagrees about version of symbol`). Left-out modules are
   normal (they need exports Google's own module builds don't have); they're not errors.
   `firmware-extra` prints how many files/MiB it added.
7. Test: the QEMU smoke test (`tools/` helpers, see `docs/02`) and real hardware with the GRUB
   "debug" entry (boot.log/logcat.log on the CHURRO-LOG partition). A misbehaving driver on one
   machine: add its module name to `features/drivers-extra/skip.txt`.
8. Record what changed and why in `docs/02-bringup-log.md` and the status in
   `docs/05-hardware-support.md`.

Rules that must hold whatever is changed: built-in kernel options stay identical except for
harmless additions; the kABI check passes with 0 differences; safety exclusions stay in
`DISTRO_DENY`/`DISTRO_DIRS` (TPM, SPI flash/MTD, watchdogs, EFI/firmware drivers, NPU — see the
safety section of `docs/05`).

## Moving to a newer recovery image or another Googlebook's image (checklist)

Most of the build reads what it needs from the input image (partition tables, the kernel's build
ID and CRCs, the shipped modules, the board audio config, the SELinux policy version) and stops
with an error when something doesn't fit. What follows is everything that is *tied to the current
image* (Lenovo "ruby", build 16452207, Android 17, GKI 6.18) and may need attention. Work through
it in order; each step says where the assumption lives and how to check it.

1. **Build once and read the log** (`churro.sh auto`). Hard failures name their cause:
   kernel patch doesn't apply → "When the kernel source changes" (§2); kABI differences → the
   driver-set checklist above; `minigbm`/`libgbm` "symbol missing" → `gfx/build-minigbm.sh`
   (AOSP branch must match the image's Android release); `audio-generic: no board audio config`.
2. **Android release pins** (only change with a new Android version, not a new build):
   - software KeyMint: `CHURRO_EMU_URL`/`CHURRO_EMU_SHA1` at the top of
     `features/security-software/patch-vendor.sh` = Google's public x86_64 emulator system image
     of the **same Android release** (sys-img `google_apis/x86_64-<API>.0_rNN.zip`). A mismatch
     shows as keystore2/KeyMint errors at boot (`Failed to construct mandatory security level TEE`,
     docs/02). Update URL + SHA1 together.
   - minigbm (`android17-release`) and Mesa/NDK pins in `gfx/build-*.sh`.
3. **Edits matched by file name — these skip silently if names change. Check them by hand:**
   - *Safety* (`features/firmware-lockdown/patch-vendor.sh`, docs/05 safety table): the list of
     removed flash/firmware tools (`flashrom futility vpd fwtool elogtool fwupd`, the futility
     executor HAL). On a new image list `vendor/bin`, `vendor/bin/hw`, `vendor/etc/init` and
     `system*/bin` for anything that writes SPI flash, EC, VPD or firmware (names containing
     flash, fw, futility, vpd, ec, gsc, tpm) and add it. The cmdline part (SPI driver + TPM
     blacklist, `spi-intel.*` flags stripped, `efi_pstore` off, in `churro.sh`) does not depend on
     names, but re-read the new vendor cmdline (`<work>/vboot/cmdline`) for new firmware-write or
     TPM options.
   - *Board power limits*: the same script edits `init.ruby.rc` (RAPL/TCC). Another device has
     `init.<board>.rc`: grep its rc files for `powercap`, `intel-rapl`, `tcc_offset`.
   - *Security HALs* (`features/security-software/patch-vendor.sh` loop, `patch-system_ext.sh`):
     Trusty/GSC HAL names. Leftovers show at boot as services crash-looping or keystore2 waiting
     for a HAL.
   - *Board audio settings*: the four cmdline options stripped in `churro.sh` and the
     `modules.blocklist` / `modules.options` lines `audio-generic` removes. Re-read both files and
     the cmdline of the new image for other `snd_*` options that force a driver or a board quirk.
4. **audio-generic assumptions** (behaviour of Google's audio HAL `dras`, found by testing this
   build; the build log line `audio-generic: configs for … over <board dir>` shows what it found):
   - the HAL takes card + config dir from `/vendor/etc/hardware_descriptor/mapping_table.binpb`
     (default entry on an unknown PC). We assume that default = the one board dir in
     `/vendor/etc/audio` and take the card name from its `audio_config.xml`. **Several board dirs**
     in a new image: find out which one the HAL picks on a PC (logcat `Startup options:
     … primary_soundcard_name …, audio_config_dir …`) and use that dir's card name (`W=` in
     `patch-vendor.sh`).
   - names hardcoded from this image: the restarted service `vendor.audio-hal-aidl` (apex rc
     `dras.core.audio.rc`); the borrowed SELinux domain `get_variant_audio` and its exec label for
     `/vendor/bin/get_variant_audio` (`vendor_file_contexts`; **if the type is gone the extra CIL
     rule makes the on-device policy compile fail = no boot**: check `grep get_variant_audio
     vendor/etc/selinux/*` first); SOF module names in the softdep lines (`snd_sof_intel_hda`,
     `snd_sof_intel_hda_generic`: check `ls vendor_dlkm/lib/modules | grep sof-intel-hda`).
   - config format: the fields Google's own `audio_config.xml` uses. If the HAL logs `fail to
     create internal card`, diff our generated file against the new image's board file and copy
     any new fields.
   - success looks like `Successfully initialized AlsaCardManager with internal card` in logcat;
     failure like `Starting primary stub module. Primary module audio will not work`. Streams
     reaching the right PCM (`resolve_config for direction:OUT pcm:(N, 0)`) but no sound = mixer:
     check `churro-mixer` ran (no avc denials for `get_variant_audio`/`audio_device`).
   - QEMU proves routing, not volume: its single-output codec has no virtual Master, so a muted
     Master on real hardware doesn't show there. Check the captured wav for non-zero samples
     (`od -An -td2 -j44 q.wav`), with a known tone played by `dras_tool aplay <wav>`.
5. **Graphics edits by pattern** (`features/gfx-mesa/patch-vendor.sh`): build.prop keys
   (`ro.hardware.egl/vulkan`, `vendor.hwc.drm.enable_color_pipeline`), `ueventd.rc`
   (`parallel_ueventd_main_loop`), DRM node labels in `vendor_file_contexts`. Grep the new files
   for the same keys; a renamed key just means the edit no longer happens.
6. **Test in QEMU before hardware.** `tools/qemu-test.sh <img> <logdir>` on a copy of the image
   whose ESP `churro/env.cfg` has `set default=1` (debug entry, so logs get written); `QEMU_EXTRA`
   adds devices. Audio check:
   `QEMU_EXTRA='-audiodev wav,id=a0,path=/tmp/q.wav -device intel-hda -device hda-duplex,audiodev=a0'`
   → the card is legacy HDA id `Intel`; expect `snd_hda_codec_generic … autoconfig`, the logcat
   success line above, and `/tmp/q.wav` growing past its 44-byte header once Android opens a
   stream. SurfaceFlinger crash loops in QEMU are a known softpipe issue, not a regression.
   Logs: CHURRO-LOG partition (`boot.log`, `logcat.log`).
7. **Then hardware**, always first with the debug GRUB entry (only it writes the logs).

## Why this is simpler than Croissant in some places and harder in others
* Simpler: no donor *system* image, no root-fs surgery for drivers on Intel Gen12+; Android's
  GKI/vendor split lets us add drivers as modules or rebuild the very same kernel.
* Harder: Android's security model is hardware-anchored (pKVM + DICE + GSC) and SELinux is
  enforcing on a user build — every change must keep labels intact and stay inside existing
  policy.
