# Project Churro

Make **Googlebook OS** (Android 17 "android-desktop" / Aluminium) recovery images bootable and
installable on generic x86_64 UEFI PCs, by *converting* Google's official image locally instead
of redistributing a ported one (same idea as Project Croissant / chromefy for ChromeOS).

> Status: **experimental** — boots to a usable Googlebook OS desktop on real hardware from USB:
> Arrow Lake laptop (Intel iGPU or NVIDIA via nouveau; Wi-Fi, audio, touchpad, Play Store / app
> installs), and older machines down to Haswell (Tiger Lake, Broadwell, Haswell) through
> an in-kernel emulator for the newer CPU instructions the image is compiled for — slower there.
> CPU floor: Haswell (AVX2). See [`docs/`](docs/) and the hardware matrix in docs/05.

## Getting the recovery image

Download the official recovery image of a Googlebook from
[aluminium-os.com/googlebookos](https://aluminium-os.com/googlebookos/) (lists every model and
build) and unzip it: the `recovery.zip` (~7.8 GB) contains
`android-desktop_signed_recovery_image.bin` (~19 GB). Churro is developed on the Lenovo Googlebook
15 (`ruby`); other models are untested. Direct links and Google's own catalog (for scripts):
[docs/07-updates.md](docs/07-updates.md#getting-a-recovery-image).

## Checking updates for the recovery image

Google's on-device updater is disabled (it can't apply updates to a converted system). Instead,
update the **clean recovery image** (the one you downloaded, not converted by Churro) on the PC:
the result is a **new clean recovery image** of the newer build, which you then convert as usual.

```bash
tools/updater/ota-check.sh android-desktop_signed_recovery_image.bin        # update available?
tools/updater/ota-update.sh android-desktop_signed_recovery_image.bin \
    --bin android-desktop_signed_recovery_image-NEWNAME.bin                # apply it (new file)
# The command below is the actual churro execution for creating the generic image, also explained further in the below chapters
# The resulting generic image created can never be OTA updated, it must be recreated from an updated clean original image
sudo ./churro.sh auto android-desktop_signed_recovery_image-NEWNAME.bin churro.img        # Creating patched Churro image from updated image
```

`ota-check.sh` asks Google which update it offers that build (exit 1 if none); `ota-update.sh`
downloads that update (a small delta) and applies it to a copy of the image with Google's own
update code, checking every partition, without touching the original. Details and limits:
[docs/07-updates.md](docs/07-updates.md).

## Quick start

Linux or WSL2, as root, ~100 GB free (kernel + Mesa builds). On Debian/Ubuntu (tested: 24.04) every
missing package is installed automatically on the first run (`lib/deps.sh`); on other distros the
script prints the list of packages to install:

```bash
sudo ./churro.sh auto android-desktop_signed_recovery_image.bin churro.img   # prepare + build
sudo tools/qemu-test.sh churro.img                                          # optional: QEMU test
```

Options: `--gfx auto|native|nouveau|mesa|soft` (graphics stack; `auto`, the default, lets the boot
menu pick from the GPUs present: Intel iGPU → `native` = Google's ANGLE-on-Intel-Vulkan (Gen12+)
or `mesa` on our i915 (older Intel, loaded only there), NVIDIA without iGPU → `nouveau`, else
`soft`; switchable in the GRUB menu) and `--packs virt,gpu,storage[,wifi]` (`wifi` = Atheros ath9k,
drop it on machines with Intel Wi-Fi) and `--data-size N`
(Android's data partition in GiB, default 12; the image is then ~26 GiB, so use a USB stick of
32 GB or more — the image's own 4 GiB fills up on first boot).
Hardware status and roadmap: [docs/05-hardware-support.md](docs/05-hardware-support.md).
`CHURRO_NPU=true` lets the NPU driver load (off by default: it froze an Arrow Lake laptop).

> ⚠ **Safety:** the Googlebook image updates firmware by itself at every boot (BIOS flash via
> flashrom/futility, device firmware via fwupd, the security chip via gscutil over the TPM). On a
> normal PC that can brick the BIOS, reflash SSDs/hubs/docks, or trigger BitLocker recovery.
> Churro always removes those tools and blocks the SPI-flash and TPM drivers; there is no switch to
> undo it. See [docs/05-hardware-support.md](docs/05-hardware-support.md#-safety-things-that-must-stay-disabled).

Write `churro.img` (or a `.img.gz` of it) to a USB drive (Rufus "DD image", Etcher, `dd`), disable
Secure Boot, boot. If it stops or hangs, boot the GRUB entry "debug": the log scrolls on screen,
the machine halts on errors instead of rebooting, and everything is saved on the stick's
**CHURRO-LOG** drive (visible in Windows): `boot.log` (kernel + Android init) and `logcat.log`
(Android's own log, e.g. why a service crashes); the previous boot's are `*.prev.log`.
Install to a disk from any Linux live session: `sudo ./churro.sh install churro.img /dev/nvme0n1`
(or `/dev/sda` for SATA / M.2 SATA, `/dev/mmcblk0` for eMMC). Supported controller modes: AHCI,
IDE, Intel VMD/RST; RST "Optane/NVMe remapping" isn't (switch the BIOS to AHCI). Android only
auto-mounts USB drives: internal and secondary disks stay untouched.

## What the conversion does

1. **Bootloader**: Googlebooks boot via coreboot/depthcharge and the image's EFI partition is empty.
   Churro builds the initrd a boot-v4 bootloader would (vendor + dlkm + generic ramdisks + extra
   modules + Android *bootconfig*) and installs GRUB + kernel there. `androidboot.boot_part_uuid`
   lets Android find its partitions on whatever disk it booted from.
2. **Kernel**: Churro rebuilds **the very same kernel** as the image's GKI from Google's public
   source (same commit, config, toolchain, release string and kABI CRCs — the image's own modules
   still load), picked automatically from the image, without KMI trimming, with small fixes in
   `kmod/patches/` and extra drivers: i915 (older Intel), simpledrm (any UEFI framebuffer), SATA (AHCI/IDE), Intel VMD, virtio, vgem, and a
   distro-like module set (Arch Linux's driver modules, ~3000) that `features/drivers-extra`
   adds to vendor_dlkm after an ABI check; Android loads them by device ID, like udev.
   `features/firmware-extra` adds their firmware (linux-firmware, Intel SOF audio, regulatory.db);
   `features/audio-generic` points Google's audio HAL at the PC's HD-audio card instead of the
   Lenovo board's.
   Updating them: checklist in docs/03, "Updating the driver set and firmware"; for a newer
   recovery image or another Googlebook's image: docs/03, "Moving to a newer recovery image".
   **Older CPUs**: the image's userspace is compiled for Panther Lake, so CPUs older than Arrow
   Lake hit instructions they lack (AVX-VNNI, AVX-IFMA, GFNI, SHA-NI, VAES, ADX, ...). The kernel
   patch `vex-emulate` emulates them on the invalid-instruction trap (dormant on CPUs that have
   them; `churro.vexemu=0` turns it off) — docs/05, "Hard floor: the CPU".
3. **Security** (`features/security-software`): the Googlebook keystore runs in a Trusty VM that
   needs x86 pKVM + pvmfw DICE + the Google Security Chip. Churro swaps in AOSP's software KeyMint
   and Gatekeeper (lock-screen PIN/password; both from Google's public Android 17 emulator image)
   and removes the Trusty/GSC HALs and services that only work on Google's hardware — the
   counterpart of Croissant's TPM emulator.
4. **Graphics** (`features/gfx-mesa`, `gfx-minigbm`, `gpu-nouveau`): Mesa built from source with
   the NDK (iris, crocus, nouveau, Zink, virgl, softpipe; NVK always, hasvk/radv optional), the
   allocator rebuilt for any Intel Xe GPU and nouveau, nouveau + NVIDIA firmware for machines
   without an iGPU; the stack is picked at boot (`androidboot.churro.gfx=`).
   **Crypto** (`features/crypto-generic`): BoringSSL rebuilt from source for any Haswell+ CPU
   (Google's build assumes Panther Lake crypto instructions), exports checked against the image:
   system + vendor copies replaced, the APEX copies (Conscrypt, HttpEngine, Wi-Fi, ...) covered by
   bind mounts at boot, so the signed APEXes stay untouched.
5. **Partitions** are patched by unpacking/repacking EROFS with SELinux labels preserved; dm-verity
   is switched off (`vbmeta` flags, device reported as unlocked/orange).

Nothing Google-owned is shipped: inputs are the user's recovery image plus files the script
downloads from public servers (Google's GKI source/toolchains, emulator image and BoringSSL;
Mesa, linux-firmware, Arch's kernel config, ...; versions pinned in `versions.env`) or builds
from source.

## Layout

| Path | What |
|---|---|
| `churro.sh` | `auto` / `build` / `install` |
| `versions.env` | every pinned version the build downloads (kernel driver config, firmware, Mesa, NDK, emulator image, BoringSSL, tools), one section each |
| `lib/` | boot image + vendor_boot parser, bootconfig, ramdisk, ESP/GRUB, EROFS/super/vbmeta patching (`lpinfo.py`) |
| `features/` | partition overlays + patch scripts: `security-software`, `firmware-lockdown`, `firmware-extra`, `drivers-extra`, `audio-generic`, `gfx-mesa`, `gfx-minigbm`, `gpu-nouveau`, `crypto-generic`, `libs-generic`, `setup-no-ota`, `debug-log` (all default), `security-trusty-vm` (experimental) |
| `crypto/` | BoringSSL builds for Android (`build-boringssl.sh` platform copy, `build-boringssl-httpengine.sh` HttpEngine's) |
| `kmod/` | Churro kernel build (`build-kernel.sh`, `profiles/`, `patches/` incl. the `vex-emulate` instruction emulator), out-of-tree pack builds |
| `gfx/` | Mesa and minigbm (graphics allocator) builds for Android |
| `tools/` | `prepare.sh` (fetch + build everything), `updater/` (check for and apply Google's updates to the recovery image), module packs, QEMU helpers, `vexemu/` + `vextest/` (emulator source and tests), dev helpers |
| `docs/` | analysis, bring-up log, architecture, device notes; `docs/notes/` = scratch |
