# Recovery images and updates

Status: **updates are built on the PC, not on the device.** Google's on-device updater stays off
(`firmware-lockdown` removes `update_engine`; see "Why Google's on-device OTA doesn't work" below).
To update, `tools/updater/ota-update.sh` turns the stock recovery image into the next build's image
locally, and `churro.sh` is run again on the result.

## Getting a recovery image

Google publishes a catalog of the official recovery images:
`https://dl.google.com/dl/edgedl/device/recovery/production_recovery.json` — one JSON entry per
model with `device`, `model`, `buildidentifier`, `url`, `filesize` (size of the `.bin`), `md5` and
`dateupdated`. It's Google's own list and covers every Googlebook model: use it in scripts. For
browsing by hand, [aluminium-os.com/googlebookos](https://aluminium-os.com/googlebookos/) shows the
images in a friendlier page (the README points users there).

Seen 2026-10-22:

| device | model | build |
|---|---|---|
| `ruby` | Lenovo Googlebook 15 | 16452207 (CL3B.260622.271.R1) |
| `lapis` | ASUS Googlebook 14 | 16452207 (271.R1) |
| `moonstone` | Acer Googlebook 14 | 16452207 (271.R1) |
| `mica` | Dell XPS Googlebook | 16471258 (273.R1) |
| `quartz` | HP Googlebook 14 | 16471258 (273.R1) |

Each `url` is `https://dl.google.com/device/recovery/<device>-user/<build>/recovery.zip` (~7.8 GB),
a zip with one file, `android-desktop_signed_recovery_image.bin` (~19 GB):

```bash
curl -fsSL https://dl.google.com/dl/edgedl/device/recovery/production_recovery.json | python3 -m json.tool
curl -fL -C - -o recovery.zip https://dl.google.com/device/recovery/ruby-user/16452207/recovery.zip
unzip recovery.zip        # -> android-desktop_signed_recovery_image.bin (unzip checks its CRC-32)
```

Checked for ruby: the zip entry's CRC-32 (`213c174b`) equals the CRC-32 of the `.bin` Churro was
developed on. The catalog's `md5` is **not** the `.bin`'s md5 (presumably the zip's; unverified).
Churro is tested on `ruby`; the other models are untested (docs/03, "Moving to a newer recovery
image or another Googlebook's image").

The catalog lags behind: it still listed 271.R1 for ruby while Google was already offering the
276.R4 update over the air. That's what `tools/updater` is for. (2026-11-11: the catalog has
276.R5 / 16693588 for ruby, lapis, mica and quartz, 276.R6 for moonstone; over the air ruby is
already offered 286.R2 / 16833189.)

## Checking for and applying updates (`tools/updater/`)

No root needed. `buildinfo.sh` and `ota-update.sh` check their packages first (`lib/deps.sh`,
profile `updater`: `gdisk curl unzip python3`, plus the erofs-utils build packages until
`tools/bin/dump.erofs` exists) and, if some are missing, print the `sudo apt-get install …` line to
run; as root they install them. `ota-check.sh` only needs curl/gzip/od (with a `.bin` it goes
through `buildinfo.sh`). On other distros the list is printed and the run continues.

```bash
tools/updater/ota-check.sh android-desktop_signed_recovery_image.bin       # is there an update?
tools/updater/ota-update.sh android-desktop_signed_recovery_image.bin \
    --bin out/android-desktop_signed_recovery_image-276.R4.bin               # build the updated image
sudo ./churro.sh auto out/android-desktop_signed_recovery_image-276.R4.bin churro.img
```

### `buildinfo.sh <recovery.bin>`
Reads the image's build properties without root (GPT → super metadata → `dump.erofs --cat` of
product_a `/etc/build.prop`) and prints eval-safe `KEY=value` lines: `FINGERPRINT`, `MODEL`,
`SDK`, `SECURITY_PATCH`, `DATE_UTC`, ... Needs `dump.erofs` ≥ 1.8 (`--cat`; Ubuntu 24.04 ships
1.7.1): built once into `tools/bin` on first use, or set `EROFS_BIN`.

### `ota-check.sh <recovery.bin | fingerprint> [--chain] [--html]`
Asks Google's checkin server which update it offers that build, the same request GMS SystemUpdate
makes (anonymous: random serial/IMEI/MAC, field set from tangalbert919/google-ota-prober). Prints
`FROM` and `OTA_TYPE` (`delta` or `full`), `OTA_PKG`, `OTA_NFO` (target build fingerprint),
`OTA_PATCH` (security patch level), `OTA_SIZE`; a summary goes to stderr. Exit 1 with "no update
offered" when there's no update for the build. `--chain` follows update after update (prints
URLs), `--html` prints a table,
`--serve [port]` gives a small browser form on 127.0.0.1 (busybox httpd).
- With a `.bin`, the build timestamp (`ro.build.date.utc`) is sent like the device does; with a bare
  fingerprint pass it as `OTA_TS=<timestamp>`. Without it the server may answer with an older
  full image instead of the delta.
- Google's server picks the package; a Googlebook (and these tools) take whatever the reply's
  `update_url` points to. A **delta** (tens to hundreds of MB) applies only to the exact build it
  was made from. A **full** (~3 GB) holds every partition whole and needs no source: it is what
  checkin offers a build Google has no delta from.
  (Google also sends a full to a device that reported a failed delta install; the tools never
  report a failure, so they don't get one that way.)

Examples. 2026-10-22: 271.R1 → `f0213a03968988d155c37c84c1cf99c1a750eb11.zip`, delta, 36.5 MB, to
`CL3B.260622.276.R4/16658739`, security patch 2026-10-01. 2026-11-11: 276.R4 →
`6a4a82fbe657a8396cbc14f90e62984ca9635900.zip`, **full**, 3.05 GB, to
`CL3B.260622.286.R2/16833189`, security patch 2026-11-01 (no delta from 276.R4; on the same day
271.R1 was offered a 164 MB delta to 286.R2). Packages live at
`https://ota.googlezip.net/packages/ota-api/package/<sha1>.zip`, public, and the name is the
file's own SHA-1.

### `ota-update.sh <recovery.bin> [out_dir | --bin <new.bin> | --in-place [--undoable] | --revert]`
Applies the update locally:
1. `buildinfo.sh` + `ota-check.sh` → the package for this build (delta or full).
2. Downloads it to `out/ota-cache/` (checked: SHA-1 = file name; a stopped download resumes on
   the next run) and, once, AOSP's prebuilt
   `ota_extractor` (from `otatools.zip` on ci.android.com, Linux x86_64; only `bin/ota_extractor` +
   `lib64/` are kept, in `out/ota-cache/otatools/`, with the CI build in `BUILD`).
3. For each partition in the package, one at a time: for a delta, cuts the source partition out
   of the `.bin` (GPT `*_a` or a logical `*_a` inside `super`, no root; a full has no source);
   applies the package with `ota_extractor` (update_engine's own code, which handles the VABC
   `LZ4DIFF` operations generic payload tools can't), writes the result, and checks it against
   the SHA-256 the payload declares for the new partition.

Partition sizes can change (286.R2: system, system_ext and product a little bigger, vendor 95 MB
bigger, the two `*_dlkm` smaller). With `--bin`, a logical partition that outgrew its place in
`super` grows where it is when the next partition is far enough (system, product, system_ext: the
alignment gap was enough), otherwise it moves to the free space at the end of `super` (vendor) —
`lib/lpinfo.py grow`, the same code `churro.sh` repacks with — and the copy gets the new `super`
metadata. A smaller partition keeps its extent. A GPT partition (boot, vendor_boot, ...) can't
grow: the script stops.

Outputs:
- `--bin <new.bin>`: a copy of the whole image with the partitions replaced at the same offsets,
  each one checked by reading it back from the new file. Never overwrites: refuses an existing
  file, builds `<new.bin>.part` and renames it only when every partition matched (removed on
  failure). The copy uses `cp --reflink=auto --sparse=always`.
- `out_dir` (default `out/ota-update`): `<partition>.img` files + `BUILD_INFO` (FROM/TO/PACKAGE).
- `--in-place`: updates the image file itself, with no 19 GB copy and nothing kept. Each partition
  is still checked by reading it back, but a run that fails or is stopped (Ctrl+C, a hash
  mismatch, a full disk, a power cut) leaves the image half updated, a mix of two builds. With a
  full package, run it again to finish: a full applies to anything, and the script prints the
  command (the half-updated image no longer tells which build it was, so `FINGERPRINT` and
  `DATE_UTC` are passed in). With a delta there is no way forward: the partitions already replaced
  no longer match what the delta expects, so keep a copy of the image, or use `--undoable`.
- `--in-place --undoable`: the same, but before a partition is replaced its whole old content is
  saved in `<recovery.bin>.undo/` and flushed to disk, and so is the head of `super`. That is
  every partition in the package, ~4 GB for 286.R2 (instead of the 19 GB of `--bin`), read and
  written once more. If the run fails or is stopped it puts the image back by itself; after a kill
  or a power cut the folder is left unfinished, the next `--in-place` refuses, and `--revert` puts
  the image back.
- `--revert`: writes the saved content back and removes the folder: the image is byte for byte what
  it was before the last `--in-place --undoable` (delta or full: it restores bytes, it doesn't
  apply anything). The folder is kept after a good update for this, until the next `--in-place`
  removes it; deleting it only gives up the way back. It belongs to that image file: delete it if
  you replace the file with another one.
  Measured with `--undoable` on the 276.R4 image, full to 286.R2, image and cache on the Windows
  drive under WSL (package and otatools already downloaded): update 4 min 13 s, undo folder
  3.8 GB, revert 36 s. Without `--undoable` the 3.8 GB save is skipped (not timed on the real image).

Space: the new image (~19 GB, less where sparse) plus ~4 GB of temporary files (one partition's
source + output; product is the largest), plus the package in the cache (3 GB for a full). With
`--bin` no `.img` files remain. Measured, delta: 1 min 35 s from an empty cache (36 MB delta +
~530 MB otatools downloads included), plus the time to copy 19 GB. Full (3.05 GB): 3 min 28 s on WSL with the package and otatools already in the cache and without
the 19 GB copy (measured on a sparse skeleton of the image); from an empty cache add the two
downloads (the package took ~2.5 min at ~20 MB/s).

Env: `CHURRO_OTA_CACHE` (cache dir), `OTATOOLS_BUILD=<ci build id>` (pin otatools; default: the
last good build of an x86_64 phone target on `aosp-android-latest-release`), `FINGERPRINT` +
`DATE_UTC` (skip `buildinfo.sh`).

Why it works: the recovery `.bin` is the stock build, byte-identical to what a Googlebook has
before updating, so the delta applies cleanly (its source hashes are checked block by block). On a
Churro install the same delta fails, because Churro has modified the partitions. A full replaces
the partitions whatever they held.

Tested on ruby 271.R1 → 276.R4 (2026-10-22): all 11 partitions (boot, init_boot, vendor_boot,
pvmfw, vbmeta, system, system_ext, product, vendor, system_dlkm, vendor_dlkm) match the target
hashes. Full 276.R4 → 286.R2 (2026-11-11): all 11 match too, read back from a `--bin` image;
system, product and system_ext grew in place, vendor moved to the end of `super`. That run used a
sparse skeleton of the 276.R4 image (GPT + `super` metadata: a full needs no source data); the
complete 19 GB run and `churro.sh` on the result are still to do. 286.R2's kernel is a new GKI
commit (`6.18.21-android17-5-g0e2640c903c1-ab16560873`; 276.R4: `-g3938c8d97142-ab16302624`), so
`churro.sh` rebuilds the kernel on it.

### `payload.py offset|parts|target <ota.zip> [partition]`
Small dependency-free reader for the zip's `payload.bin` (update_metadata.proto): where the
payload starts in the zip, each partition's old/new size, and a partition's target size +
SHA-256.

### Limits
- Only the partitions in the package change, in slot A (a real Googlebook installs into slot B and
  switches; Churro boots slot A and keeps its slot flags). `system_b` (preloaded apps and
  precompiled code for first boot), `ota_recovery_a/b` and the ChromeOS firmware/installer
  partitions stay at the old build; churro.sh doesn't use them, and outdated precompiled code is
  ignored and rebuilt by Android.
- The GPT layout is kept: a boot-type partition bigger than its GPT partition stops the script.
  Logical partitions grow inside `super` only (12 GiB, ~4.4 GiB free in Google's image; a moved
  partition's old place stays empty, and `churro.sh` needs free space there for its own repacks).
- A partition that got smaller leaves the old build's bytes after its end, inside its extent
  (nothing reads them: the filesystem's own size counts, and Churro turns verification off).
- One step per run. If Google offers a chain (271 → X → Y), run `ota-update.sh --bin` again on the
  new image.
- `ota-update.sh` assumes one run at a time (it removes leftover `work.*` dirs in the cache).
- `--in-place` without `--undoable` has no safety net (above). With it, it is as safe as the undo
  folder: with the folder deleted, or on a disk that loses flushed data in a power cut, a broken
  run leaves a mixed image. `--revert` doesn't check that the image is still the one the folder
  was made from.

## Why Google's on-device OTA doesn't work on Churro

During setup Google's updater downloaded the delta, which failed its source check
(`verifyPayloadMetadata()`: Churro modifies the partitions), and then got a ~3 GB full update. To
keep that from happening `firmware-lockdown` removes `update_engine`. Setup also makes such an
update mandatory when checkin marks it required, and with no way to install it setup was stuck
("Something went wrong"; Back, "Reset update" and "Restart now" all lead back to it): `setup-no-ota`
sends that step on to the app updates, as Google's QR/NFC provisioning flows do (docs/03).

| | Churro | GBRUNCH |
|---|---|---|
| Kernel | rebuilt GKI on the ESP (extra drivers) | Google's original kernel + modules |
| system / super bytes | vendor + system_ext repacked inside `super` | original bytes kept on disk |
| Vendor actually used | the repacked one | a *derived vendor view* on its own partition (also modified) |
| AVB / dm-verity | vbmeta flags off | on for system; unlocked/orange overall |
| Owned config | edits inside vendor | `/oem` partition, `androidboot.init_rc=/oem/init.gbrunch.rc` |
| OTA | broken (delta OTA source check fails) | "not implemented or validated" (README) |

GBRUNCH keeps the originals *on disk*, but it boots its own vendor copy, so an OTA would update
partitions it doesn't run. Neither project gets working on-device Google updates today.

### What an on-device OTA would need
1. **Original partitions byte-identical** (`super`, `boot`, `vendor_boot`, `vbmeta`): incremental
   OTAs verify the source hashes first. → no repacking; dm-verity on.
2. **Our boot path follows the slot**: update_engine writes slot B (incl. `boot_b`, `vendor_boot_b`)
   and flips the active slot; GRUB must boot the matching slot's kernel/ramdisk (or ours, see 3).
3. **Kernel matches the new build**: Google's `vendor_dlkm`/`system_dlkm` modules are built
   against that build's GKI. A rebuilt Churro kernel would be the old version → modules refuse to
   load. Options: Google's kernel as-is (GBRUNCH) + only KMI-clean extra modules; or re-run
   `prepare` after every OTA (kernel compile — can't happen on the device).
4. **All changes outside Google's partitions**, applied at runtime from an owned partition:
   - init rc via `androidboot.init_rc` (import stock rc, override services) — GBRUNCH approach;
   - files replaced by bind mounts from `/oem` (crossystem stub, Mesa, firmware); needs SELinux
     `mounton` permissions → policy is in vendor, so this is the hard part (GBRUNCH hit it too);
   - kernel cmdline is ours (GRUB) → blacklists/`efi_pstore`/spi-intel flags survive an OTA.
5. **Safety without deleting files**: flash tools can only be neutralised (blacklisted drivers,
   bind-mounted stubs, services stopped). Each one must be re-checked against every new build;
   anything missed comes back silently after an OTA. Board RAPL/TCC `write` lines in vendor rc can't
   be removed without editing vendor (would need a later override that restores sane values).
6. **Google must serve the OTA**: unregistered device, unlocked boot, software KeyMint — unverified.

## Re-churro instead (keeps safety)
Build a newer image on the PC and convert it again: the image side is done by `ota-update.sh
--bin`, and every safety edit is re-applied and checked by `churro.sh` each time. Still open:
keeping the user's data, i.e. rebuilding every partition except `userdata` in place on an existing
install (same layout, userdata already last). Needs the same userdata format/encryption across
versions and a `churro.sh` step that writes a new image onto an installed disk without touching
userdata. Also re-check the new build against docs/03, "Moving to a newer recovery image".
