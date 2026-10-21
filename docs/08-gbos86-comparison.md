# 08 — Comparison with gbOS86 (linuxkid473/gbos-x86)

Read on 2026-10-21 (commit 25ed180). gbOS86 runs the same Google build as Churro
(`CL3B.260622.271.R1`, 16452207) but from the **`lapis`** board's recovery, on ordinary Intel
laptops (maintainer: Dell Latitude 5300, Whiskey Lake). 19 machines reported, 7 fully working.

## Same starting point, different shape

| | gbOS86 | Churro |
|---|---|---|
| Input | official recovery, downloaded by `build.sh` itself (`dl.google.com/.../lapis-user/16452207/recovery.zip`, 7.7 GB; streams only 6 partitions) | official recovery `.bin` the user passes to `churro.sh auto` |
| Output | USB image: FAT32 volume holding `super.img` + scripts ("standard" = live/installer, "looper" = persistent stick) | the recovery's own GPT disk, converted in place (Googlebook layout kept) |
| Kernel | own build of android17-6.18 with a laptop config (`configure_whl.py`), drivers built in; **prebuilt `BOOTX64.EFI` committed**; Google's vendor modules not used | Google's GKI rebuilt bit-compatible (4501 CRCs equal): Google's modules (xe, iwlwifi, SOF) load, ~3000 distro modules added |
| Boot | kernel EFI stub → busybox stage0 (in the kernel) mounts the erofs partitions from `super.img` via loop + dm-linear, runs `hook.sh` (bind mounts), `switch_root` into Android init's `selinux_setup` (Android first stage skipped) | GRUB → kernel + boot-v4-style initrd → Android's own first-stage init (real fstab, `boot_part_uuid`) |
| Changes to Google's files | bind mounts at boot (`hook.sh`), files on disk untouched | partitions repacked at build time (erofs, labels kept) |
| Google binaries in the repo | yes: modified `libcrypto`, `libz`, `libkm_compat`, gralloc copies (`usb/patched/`) | none: everything is built or taken from the user's image at build time |
| Build host | macOS or Linux with docker | Linux/WSL (packages auto-installed) |

## Filesystem

- **gbOS86:** system/vendor/... stay erofs inside a `super.img` **file on FAT32** (kept under 4 GB);
  `/data` and `/metadata` are ext4 partitions (`GBOS_DATA`, `GBOS_META`) created **without the
  encrypt feature** (no file-based encryption), or tmpfs in live mode. Logs and config live on the
  same FAT volume, written during the session (their README: always shut down from Android, FAT
  has no journal).
- **Churro:** the Googlebook GPT layout as-is: raw `super` partition (dynamic partitions, erofs),
  vbmeta/boot slots, `userdata` grown to the disk and formatted by Android with **file-based +
  metadata encryption** (software KeyMint). The only FAT partition is CHURRO-LOG (fixed-size log
  files, overwritten in place, never resized).

## What gbOS86 does better

- **Install and update from the stick:** boot menu (live / install / boot installed); NVMe, eMMC and
  SATA targets with a serial-number confirmation; **Update keeps data**. Churro: `churro.sh install`
  from a Linux live, no update path yet (docs/07).
- **Downloads the recovery itself**, with a dry run that lists every download; 30–60 min first build.
- **Porting tooling:** `tools/check_new_build.sh` + `tools/port_build.sh` re-derive every patch for a
  new Google build (pattern-based, hash-pinned), with tests.
- **`libz.so` fix already done:** `tools/patch_libz_adler.py` turns `adler32_z`'s SIMD-gate `je` into
  a jump to its scalar loop (6 bytes): about half of their remaining emulation, our biggest
  `vpdpwssd` source too. Churro's plan is a source rebuild (docs/05 "To do: rebuild libz.so").
- **Pre-Gen12 Intel keeps Google's own graphics stack** (ANGLE on ANV, `vulkan.intel.so`) on their
  i915: hardware Vulkan/skiavk on Skylake–Ice Lake. Churro sends pre-Gen12 to Mesa GL (iris/crocus).
  Worth a test on a Gen9–11 machine: `native` with our i915 (ANV supports the i915 KMD); Gen8
  (T300FA) has no ANV anyway.
- **AMD:** experimental software rendering (SwiftShader) and RADV builds; Churro has amdgpu kernel
  support only.
- **Hardware reports at scale:** `hwdetect.txt` per boot (DMI, devices without driver, missing
  firmware), a website and a tested-laptops table.
- **i915 colour fixes** for drm_hwcomposer on eDP (gamma LUT ignored, colorspace/full range).

## What Churro does better

- **Safety lockdown:** gbOS86 has no code for firmware updaters (fwupd, flashrom/futility/vpd), TPM
  access by gscutil/check_tpm_clear (only `gscd` is removed), or `efi_pstore` (its debug config turns
  `EFI_VARS_PSTORE` on); it removes only vold's `usb` wildcard (to protect its own stick), leaving
  the `nvme[1-9]` / `mmc_host` ones that can expose internal disks. Not verified on their images
  whether these services run; nothing in their scripts stops them.
- **SELinux enforcing** (gbOS86: permissive, `androidboot.selinux=permissive` + kernel `gbos_permissive`).
- **Encryption kept** on /data; Android's own first-stage mount and fstab.
- **Google's kernel modules stay usable** (kABI-identical kernel): newer Intel (xe), SOF audio and
  Wi-Fi from Google's build, plus a distro-wide driver set loaded by ueventd.
- **Crypto traps:** BoringSSL rebuilt from source for every copy (system, vendor, APEXes, Cronet's
  `libcrypto_httpengine`), covering SHA-NI, VAES, VPCLMULQDQ, ADX; gbOS86 redirects only SHA-256
  in libcrypto (VAES/CLMUL stay emulated).
- **Emulator:** run-ahead and native AES/CLMUL fast paths; ADX on Haswell (gbOS86 needs AVX,
  "6th gen and newer").
- **NVIDIA:** nouveau display + NVK/Zink; gbOS86 has no NVIDIA support.
- **Lock screen:** AOSP's software Gatekeeper + KeyMint pair; gbOS86's own `soft_gk` tokens are not
  trusted by its KeyMint (auth-bound keys don't work there).
- **No Google binaries in the repo.**

## Ideas to take

1. libz: their scalar-path patch is a 6-byte change; a source rebuild (our plan) avoids shipping a
   modified Google binary but costs more work. Either removes the top `vpdpwssd` source.
2. Try `native` (Google's ANV + skiavk) on Gen9–11 Intel with our i915.
3. Recovery download in `churro.sh` (URL + sha256 in `versions.env`).
4. On-device installer/updater that keeps data (docs/07).
5. A per-boot hardware report like `hwdetect.txt` in the debug log.
