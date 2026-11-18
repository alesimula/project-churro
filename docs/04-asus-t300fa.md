# 04 — Asus Transformer Book T300FA (first real-hardware target)

## Hardware vs. what Churro needs

| Part | T300FA | Churro support |
|---|---|---|
| CPU | Intel Core M-5Y10 (Broadwell-Y), VT-x/VT-d | x86_64 GKI ✓. pKVM not needed (software security, `kvm-intel.pkvm=0`) |
| GPU | Intel HD 5300 (Gen8) | **not** handled by the image (xe = Gen12+ only) → Churro kernel `i915` + Mesa `iris` (GL ES 3.2). Vulkan: Mesa `hasvk` optional |
| Display | 12.5" 1366×768 eDP, touch | i915 KMS; touch = I²C-HID over Intel LPSS (`i2c-hid-acpi`, `i2c-designware`, in the image) |
| Storage | 64/128 GB eMMC (SanDisk DF4xxx) + HDD in dock via USB | `sdhci-pci` + `sdhci-acpi` from the Churro kernel are in the `storage` pack (first-stage ramdisk), so booting from eMMC works. USB boot works out of the box (usb-storage built in) |
| Wi-Fi | Atheros AR9565 (Notebookcheck review unit; some listings say Intel 7265) | AR9565 = `ath9k`, firmware-less → opt-in `wifi` pack (in-tree cfg80211 + mac80211 + ath9k from the Churro kernel). It replaces the image's out-of-tree cfg80211/mac80211, so the vendor iwlwifi won't load with it. Intel 7265 would instead need `iwlwifi-7265D-29.ucode` (TODO firmware feature) |
| Audio | Realtek ALC233 (HDA) | `snd-hda-intel` in the image. The vendor cmdline forces SOF (`snd_intel_dspcfg.dsp_driver=3`); if there is no sound, boot with `snd_intel_dspcfg.dsp_driver=1` |
| RAM | 4 GB | OK for Android 17, tight |
| Firmware | UEFI 64-bit | GRUB x86_64-efi; disable Secure Boot |

## Build

In WSL/Linux as root, from the repo:

```bash
sudo ./churro.sh auto android-desktop_signed_recovery_image.bin churro.img --packs virt,gpu,storage,wifi
```

No `--gfx` or i915 option needed: i915 ships with `drivers-extra` and only loads on GPUs the
image's `xe` doesn't drive (the HD 5300 is one), and the boot menu then picks `mesa` by itself.
The same image keeps booting Gen12+ machines on Google's stack.

Check the Wi-Fi chip first (Windows Device Manager → Network adapters): "Qualcomm Atheros" →
keep `wifi`; "Intel Dual Band Wireless-AC 7265" → drop `wifi` from `--packs`.

First run downloads ~4 GB (kernel source, clang, rustc, NDK, Mesa, emulator image for KeyMint) and
builds the kernel with its distro-like module set (~12 min on 20 cores) and Mesa (~3 min): about
28 min in all on a Core Ultra 7 255HX in WSL (measured 2026-11-18, empty cache). Everything is
cached in `/var/cache/churro`.

## Write to USB and boot

1. Windows: Rufus → select `churro.img` → "DD image" mode (or Etcher). ≥ 32 GB stick.
2. T300FA: BIOS (F2) → Security → Secure Boot **off**; Boot → USB first (or F12/Esc boot menu).
3. GRUB menu: default "Googlebook OS (Churro)". If the screen stays black, try
   "Graphics: other stacks → Mesa software rendering", or "debug console" to see kernel output.

## Install to the eMMC (once USB boot works)

Boot any Linux live USB on the tablet (Ubuntu), copy `churro.img` and the repo, then:

```bash
sudo ./churro.sh install churro.img /dev/mmcblk0
```

This writes the image, moves the backup GPT to the end, grows userdata over the free space and
switches the ESP to `boot_source=internal`.

> **Update:** the T300FA's Core M (Broadwell) lacks GFNI/AVX-VNNI, which Googlebook userspace
> uses from the very first program (`init`), so it cannot boot this image (see 02, "Older CPUs").
> With the `#UD` emulator it now gets through first-stage `init`; the next stop was `vaesenc ymm`
> in `libcrypto.so` (BoringSSL FIPS self-test, SIGILL in second-stage `init`), which is now
> emulated too (docs/05). The next stop after that was a REX-prefixed `sha1nexte %xmm9,%xmm1`
> in the same FIPS module (SHA-NI on xmm8–15), now handled as well. A full-image scan found no
> other Broadwell gaps on the boot path. Not yet re-tested on the device.

## What to report back

- Boot the GRUB entry "debug", then plug the stick into Windows and send `boot.log` from the
  **CHURRO-LOG** drive (works even after a hang + holding the power button).

- Does GRUB show? Does the kernel get to Android's boot animation?
- Output of the "debug console" entry if it stops (photo of the screen is fine).
- With a USB keyboard + the serial-less tablet, logs are hard to get: if it reaches the UI,
  Settings → About → tap build number won't enable adb on a user build – we'll add a
  Churro debug feature (userdebug-style adb) next.
