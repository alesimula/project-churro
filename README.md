# Project Churro

Make **Googlebook OS** (Android 17 "android-desktop" / Aluminium) recovery images bootable and
installable on generic x86_64 UEFI PCs, by *converting* Google's official image locally instead
of redistributing a ported one (same idea as Project Croissant / chromefy for ChromeOS).

> Status: **experimental** — boots to a usable Googlebook OS desktop on real hardware (Arrow Lake
> laptop, from USB, "safe display" GRUB entry): Wi-Fi, USB input, Play Store / app installs work;
> no sound or touchpad yet. Needs an Alder Lake-or-newer CPU. See [`docs/`](docs/).

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
Install to a disk from any Linux live session: `sudo ./churro.sh install churro.img /dev/nvme0n1`.

## What the conversion does

1. **Bootloader**: Googlebooks boot via coreboot/depthcharge and the image's EFI partition is empty.
   Churro builds the initrd a boot-v4 bootloader would (vendor + dlkm + generic ramdisks + extra
   modules + Android *bootconfig*) and installs GRUB + kernel there. `androidboot.boot_part_uuid`
   lets Android find its partitions on whatever disk it booted from.
2. **Kernel**: the image's GKI kernel works for Intel Gen12+ machines. For everything else Churro
   rebuilds **the very same kernel** from Google's public source (same commit, config, toolchain,
   release string and kABI CRCs — the image's own modules still load) without KMI trimming and with
   extra drivers: i915 (older Intel), simpledrm (any UEFI framebuffer), AHCI, virtio, vgem, and a
   distro-like module set (Arch Linux's driver modules, ~3000) that `features/drivers-extra`
   adds to vendor_dlkm after an ABI check; Android loads them by device ID, like udev.
   `features/firmware-extra` adds their firmware (linux-firmware, Intel SOF audio, regulatory.db);
   `features/audio-generic` points Google's audio HAL at the PC's HD-audio card instead of the
   Lenovo board's.
   Updating them: checklist in docs/03, "Updating the driver set and firmware"; for a newer
   recovery image or another Googlebook's image: docs/03, "Moving to a newer recovery image".
3. **Security** (`features/security-software`): the Googlebook keystore runs in a Trusty VM that
   needs x86 pKVM + pvmfw DICE + the Google Security Chip. Churro swaps in AOSP's software KeyMint
   (taken from Google's public Android 17 emulator image) and removes the Trusty/GSC HALs — the
   counterpart of Croissant's TPM emulator.
4. **Graphics** (`features/gfx-mesa`, `gfx-minigbm`, `gpu-nouveau`): Mesa built from source with
   the NDK (iris, crocus, nouveau, Zink, virgl, softpipe; NVK always, hasvk/radv optional), the
   allocator rebuilt for any Intel Xe GPU and nouveau, nouveau + NVIDIA firmware for machines
   without an iGPU; the stack is picked at boot (`androidboot.churro.gfx=`).
   **Crypto** (`features/crypto-generic`): BoringSSL rebuilt from source for any Haswell+ CPU
   (Google's build assumes Panther Lake crypto instructions), exports checked against the image.
5. **Partitions** are patched by unpacking/repacking EROFS with SELinux labels preserved; dm-verity
   is switched off (`vbmeta` flags, device reported as unlocked/orange).

Nothing Google-owned is shipped: inputs are the user's recovery image plus files the script
downloads from Google's public servers (GKI source/toolchains, emulator image) or builds from source.

## Layout

| Path | What |
|---|---|
| `churro.sh` | `auto` / `build` / `install` |
| `lib/` | boot image + vendor_boot parser, bootconfig, ramdisk, ESP/GRUB, EROFS/super/vbmeta patching (`lpinfo.py`) |
| `features/` | partition overlays + patch scripts (`security-software`, `gfx-mesa`, `gfx-minigbm`, `gpu-nouveau`, `crypto-generic`, `security-trusty-vm`) |
| `crypto/` | BoringSSL build for Android (`build-boringssl.sh`) |
| `kmod/` | Churro kernel build (`build-kernel.sh`, `profiles/`), out-of-tree pack builds |
| `gfx/` | Mesa and minigbm (graphics allocator) builds for Android |
| `tools/` | `prepare.sh` (fetch + build everything), module packs, QEMU helpers, dev helpers |
| `docs/` | analysis, bring-up log, architecture, device notes; `docs/notes/` = scratch |
