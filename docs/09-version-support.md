# 09 — Supporting many image versions over time

Status 2026-11-12: steps 1–4 of the implementation order (at the end) are in: the build reads
the image's kernel and Android build, picks the patch folders and the pin files from them, says
when an image is newer than anything tested, and lists the edits that found nothing to change.
Steps 5–6 are not done. There is still exactly one folder of each kind (`kmod/patches/6.18`,
`gfx/minigbm-patches/api37`, `gfx/mesa-patches/26.2`) and one pin file (`api37`): they cover
every image seen so far (table below). Self-check of the selection rules: `lib/versions-test.sh`
(no image, root or network).

## Goal

A Churro checkout taken at any later date (10 months, two years, still maintained):
- converts **every image an earlier checkout converted**: support for a new image is added
  beside the old one, never in its place;
- on an image it doesn't know, either works (nothing it depends on changed) or **stops with a
  message that names what is missing**; it never borrows a neighbour's patches or pins silently
  where that can produce a broken image.

Not a goal: new kernels or Android releases working without anyone touching the project.

## What changes between images: three independent things

The kernel and the rest of the image move separately (286.R2 brought a new kernel commit with
the same BoringSSL; the reverse can happen), so one "version" key is not enough.

| | Read from | Key | Things that follow it |
|---|---|---|---|
| **Kernel** | version string in the image's kernel, `6.18.21-android17-5-g<commit>-ab<build>` (`tools/prepare.sh`) | series `6.18` + Google's kernel build number `ab…` (only goes up; the commit hash can't be ordered) | `kmod/patches`, the Arch config tag (driver list); source, clang, Rust, bindgen already come from the image |
| **Image userspace** | product `build.prop` (`tools/updater/buildinfo.sh`) | API level (`37` = Android 17) + Google's image build number (`ro.build.version.incremental`, e.g. 16833189) | minigbm, its patches and the AOSP headers it builds with, emulator image (KeyMint, Gatekeeper, libz, bionic), `BORINGSSL_REV`, `BORINGSSL_HTTPENGINE_REV`, `LIBVA_VER` |
| **Nothing in the image** | our choice | Mesa's own release (`MESA_VER`) for its patches; none for the rest | Mesa + its patches, libdrm, NDK, linux-firmware, sof-bin, regdb, erofs-utils, secilc, build-tools, Go |

The `-5` in `android17-5` is the kernel's module-interface generation. If it changes, Google's
modules and ours change together; the export check (below) catches it. Treat it like a new series.

## The rule: "from this build on", newest that is not newer than the image

Every kernel-dependent or image-dependent item has a base entry for its series / API level and,
only when something breaks, further entries named after the first build that needs them. For an
image, take the entry with the highest build number that is ≤ the image's. No entry at all for
the image's series or API level → stop and say what to create.

Entries are added **when a check fails**, not for every build Google ships: 271.R1, 276.R4 and
286.R2 all build with the same patches and pins.

The three kinds of patch folder use one function, `version_dir <root> <series> <number>`
(`lib/versions.sh`): folders are `<series>` or `<series>-<N>` ("from N on"), each a complete set;
it returns the highest N ≤ the number in the version's own series, else the newest older series
(with a line in the log, since those patches may not apply), else it fails.

| Patches | Folder names | Series / number taken from |
|---|---|---|
| `kmod/patches/` | `6.18`, `6.18-ab17000000` | kernel version string: `6.18`, the `ab` build number |
| `gfx/minigbm-patches/` | `api37`, `api37-16900000` | image: API level, image build number |
| `gfx/mesa-patches/` | `26.2`, `26.2-5` | `MESA_VER` = 26.2.4: `26.2`, `4` |

### Kernel: patch folders
```
kmod/patches/6.18/               the *.patch files + series.env (ARCH_LINUX_CONFIG_TAG)
kmod/patches/6.18-ab17000000/    a full set, used from kernel build 17000000 on (only if needed)
kmod/patches/6.24/               next series: copy the newest folder, rebase or drop patches
```
- Folders are named after the series, not the point release: Google merges 6.18.x updates into
  the same branch all the time (docs/03 §2 has the reasoning and the ChromeOS/GKI history).
- A "from build" folder is a complete copy, not a layer over the base: under 20 small files, and each
  folder can be read alone. A fix that applies to both goes into both.
- A series with no folder uses the highest older series (6.20 → `6.18/`) and says so in the log;
  patches that then don't apply stop the build, as now.
- Before applying, try each patch in reverse (`patch -R --dry-run`): if that works the source
  already has it → skip and log. (Today `patch -N` stops the build in that case.)
- `series.env` (read before `versions.env` by `tools/prepare.sh` and `kmod/build-kernel.sh`)
  holds what follows the kernel besides the patches:
  - `ARCH_LINUX_CONFIG_TAG`, **pinned once per series, not looked up.** It is only the driver
    list (the code is Google's, the safety exclusions are Churro's own lists), so "newest" is not
    dangerous, but it buys nothing and has ways to go wrong: the newest tag *overall* is another
    series (Arch 7.3.4 on 2026-11-11: 105 module options of the 6.18.9 list gone, 273 new ones
    that a 6.18 source doesn't have); the newest tag *of the series* only stops moving once Arch
    has left the series; and Arch renamed the file (`config` up to 6.18.9, `config.x86_64` from
    6.18.13 on), so a lookup written today would already get a 404. Within a series the list
    doesn't move: 6.18.9 and the last 6.18 tag (6.18.13) both have 6227 modules, only tool
    version strings differ. A new series needs a person anyway (its patch folder), so its tag is
    one more line then. For 6.18 the tag stays `6.18.9.arch1-1`, the one everything was tested with.
  - `ARCH_LINUX_CONFIG_FILE`: that file's name (`config`; the next series will need
    `config.x86_64`).
  - `CHURRO_TESTED_KBUILD`: the newest kernel build converted and booted with the folder; a
    newer one builds and `prepare.sh` prints a notice.
  `ARCH_LINUX_CONFIG_TAG` in the environment still wins.
- The folder is chosen by `kernel_patch_dir` (`lib/versions.sh`); `prepare.sh` logs it
  (`kernel patches: kmod/patches/6.18`) and hashes that folder's patches into the kernel cache key.

### Image userspace: pin files
```
versions.env                 what follows nothing in the image (Mesa, firmware, NDK, tools …)
versions/api37.env           Android 17 images: minigbm + header commits, AIDL versions, emulator
                             image, BoringSSL revs, libva
versions/api37-16900000.env  only the pins that differ from image build 16900000 on (if needed)
versions/api38.env           next Android release
```
- Pin files, unlike patch folders, can hold just the differences: every line is
  `: "${NAME:=value}"`, which keeps a value that is already set. Reading order = most specific
  first: environment, then the matching "from build" files from newest to oldest, then
  `apiNN.env`, then `versions.env`. The existing "override from the environment" keeps working.
- No `apiNN.env` for the image's API level → stop ("Android 18 image: create versions/api38.env,
  see docs/09"). Never read another release's file: another release's bionic or KeyMint can
  match by symbol list and still differ inside (`lib/emu-image.sh`, `emu_same_api`).
- **minigbm is pinned per Android release.** It follows the image's graphics services (allocator,
  mapper, HALs), not the kernel: the DRM interfaces it uses are stable. Its commit and the seven
  AOSP header commits are `MINIGBM_*` in `versions/api37.env`; the Android API level it is
  compiled for is the image's (`CHURRO_API`). Still in `gfx/build-minigbm.sh`: the AIDL versions
  it compiles (`graphics.common` 7, `common` 2: a release that needs others changes the script),
  the NDK target (`API=35`, follows `NDK_VER`) and the build-tools release the AIDL compiler
  comes from (r36: a tool, not tied to the image).
- **minigbm's patches** are in `gfx/minigbm-patches/api37/`, chosen by the rule above from the
  image's API level and build: they apply to the source the pin file selects, so they are keyed
  the same way. An Android 18 image without an `api38/` folder gets `api37/`'s (and the log says
  so); if they no longer apply, the build stops there. The build log names the folder
  (`minigbm built: … (patches: api37)`).
- `LIBVA_VER` follows the Android release too (the image's VA-API version) but stays in
  `versions.env`: it is part of the Mesa build, which is built once for every image.
- `CHURRO_TESTED_BUILD` (in `apiNN.env`): the newest image build converted and booted; a newer
  one builds and `churro.sh` prints a notice.
- The scripts read `versions.env` one by one (16 of them). `churro.sh build` exports the image's
  API level and build number (`CHURRO_API`, `CHURRO_IMAGE_BUILD`, from `buildinfo.sh`) before the
  features run and logs them (`image: CL3B.260622.286.R2, Android API 37, build 16833189`);
  `versions.env` itself then reads the matching files. A script that needs a release pin and is
  run alone needs `CHURRO_API=37` in its environment (else: unset variable).
- **Caches follow the pins**, so switching between images of different releases never reuses
  the other one's files: the unpacked emulator image is `emu-<partition>-<zip name>` (its
  Gatekeeper beside it), minigbm's sources `minigbm/src-<hash of its pins>`, BoringSSL
  `src-<commit>` (as before).

### Mesa: patches follow the Mesa release, not the image
`MESA_VER` is our choice and one Mesa build serves every image, so its patches are keyed on
Mesa's own version: `gfx/mesa-patches/26.2/` for 26.2.x, chosen by the rule above (a 26.3 or
27.0 without a folder gets the newest older one, with a line in the log; a point release that
needs different patches gets `26.2-<c>/`). `prepare.sh` hashes the chosen folder into Mesa's
cache key and `build-mesa.sh` logs it (`Mesa 26.2.4, patches: gfx/mesa-patches/26.2`). This
mainly keeps a one-off `MESA_VER=…` from picking up patches written for another release, and
lets a new release's patches be added beside the old ones. Mesa only becomes per-Android-release
if a newer Mesa stops running on an older Android (then `MESA_VER` moves into `apiNN.env`; the
patch folders stay as they are).

## The checks that decide

| Check | Catches |
|---|---|
| patch applies / is already in the source (skipped) | kernel source moved under a patch |
| kABI: 0 of N GKI exports differ (`prepare.sh`) | kernel config or patches changed the module interface |
| modules "left out by the ABI check" (`drivers-extra`) | extra drivers that don't fit Google's modules |
| minigbm: every symbol the image's binaries use exists | minigbm pin older than the image's |
| BoringSSL: image's exports all present; HttpEngine: identical | BoringSSL pins outside the image's window |
| emulator image API = image API | wrong Android release |
| SELinux policy compiles (`tools/check-sepolicy.sh`) | features' rules vs the image's policy |
| HttpEngine version in the image ≠ `BORINGSSL_HTTPENGINE_FOR` → note (`features/crypto-generic`) | exports equal, commit not. The version is the `150.0.7871.41` string in the Tethering APEX's `libhttpengine.so`; 276.R4 and 286.R2 carry the same file |
| edits matched by file or key name that found nothing → `NOTE:` where it happens, all listed again before `done:` (`lib/note.sh`, `CHURRO_NOTES`) | renamed tools, rc files, HALs, props, cmdline options: firmware-lockdown (tool list, crossystem, power limits, fstab, timberslide, update_engine), security-software (Trusty/GSC HALs, VM launcher, VINTF entries), audio-generic (module options, cmdline), gfx-mesa (graphics props, colour pipeline, ueventd), setup-no-ota, display-density. On 286.R2 the list is empty (the first run listed two secretkeeper files: the script assumed every HAL has an `.rc` and an `.xml` of the same name, Google's secretkeeper doesn't; it now lists the exact files) |

These compare names and symbols, not behaviour: a passing build is "nothing known is wrong".
That is why the table below records what was actually booted.

## Tested images (keep this table up to date; it is the "earliest tested" record)

| Image (ruby) | Image build | Kernel | Patches | Pins | Built | Booted |
|---|---|---|---|---|---|---|
| CL3B.260622.271.R1 | 16452207 | 6.18.21-android17-5 ab16302624 | `6.18` | `api37` | Oct 2026 | MSI, VivoBook, G20AJ, T300FA |
| CL3B.260622.276.R4 | 16658739 | same (ab16302624) | `6.18` | `api37` | Oct–Nov 2026 | G20AJ, T300FA, MSI, VivoBook |
| CL3B.260622.286.R2 | 16833189 | 6.18.21-android17-5 ab16560873 | `6.18` | `api37` | 2026-11-11, 33 min 46 s (kernel rebuilt, Mesa cached) | T300FA |

(The 286.R2 row was built before steps 1–3; the rebuild that checks them is step 2/3's "Check"
below. The "Booted" column for the first two rows was filled from docs/02 and the
hand-off notes, not from a per-image record: correct it where it is wrong.)

## Maintenance rule

A change made for a new image must not change what an image in the table gets, unless it was
rebuilt with the change. In practice: a patch or pin that has to differ for the new build goes
into a new "from build" entry; an edit to an existing entry (a bug fix) applies to every build
that uses it and is noted in the bring-up log.

## What code can't guarantee

- **Downloads.** Kernel source and toolchains come from android.googlesource.com by commit
  (permanent). Per kernel build `prepare.sh` also needs two small files from ci.android.com
  (`manifest_<build>.xml`, 10 KB, and `vmlinux.symvers`, 260 KB); if Google drops old CI builds,
  an old image no longer builds from an empty cache. **TODO (maybe, one day):** keep both files
  in the repo. It would be one pair per kernel build, i.e. per kernel commit Google ships, not
  per series: about 270 KB each time an image update brings a new kernel (two so far:
  16302624, 16560873), and they must be saved while CI still has them. That only stays
  practical if the build files them itself (e.g. `prepare.sh` copies what it downloaded into
  `kmod/builds/<build>/` and uses that copy first), so nobody has to remember. The emulator
  image, build-tools and Arch config are fixed URLs with a checksum or a tag.
- **Old images to test with.** Google's catalog only lists the newest recovery image. The OTA
  packages are public and named by their hash (docs/07), so an older build's partitions can be
  rebuilt from any `.bin` plus that build's full package, while Google keeps serving them.
- **The host.** New Ubuntu/WSL releases change compilers and tools under the build.
- **Play system updates** replace APEXes (Conscrypt, Tethering) on the device after install,
  independent of any image version (docs/05).

## Implementation order (each step builds and is checked on its own)

1. **Keys.** DONE. `prepare.sh` takes the series and build from the kernel's version string;
   `churro.sh build` takes API level + image build from `buildinfo.sh` and exports them.
2. **Patch folders.** DONE. `kmod/patches/6.18/` + `series.env`; `kernel_patch_dir`
   (`lib/versions.sh`) with a self-test on made-up folders (`lib/versions-test.sh`); a patch the
   source already contains is skipped; cache hash on the chosen folder. Check: the 286.R2
   rebuild gives the same kernel (`kABI check: 0 of 4503 … differ`, +3123 modules, 55 left out).
3. **Pin files.** DONE. `versions/api37.env` (emulator image, BoringSSL commits, minigbm
   commits; moved, not copied), the reading order in `versions.env`, caches keyed on the pins.
   Check: the 286.R2 rebuild's lines for minigbm (49 and 22 symbols, all present), BoringSSL
   (2694 and 638 exports, 0 extra; HttpEngine 323 identical) and the emulator libraries are the
   same as before.
4. **New checks.** DONE (2026-11-12). HttpEngine version note; list of edits that found nothing
   (above). With them: `gfx/minigbm-patches/api37/` and `gfx/mesa-patches/26.2/`, chosen by
   `version_dir`. Checked: the 286.R2 rebuild (13 min 51 s, Mesa rebuilt: its build script
   changed) logs `patches: api37` and `gfx/mesa-patches/26.2`, no HttpEngine note, and listed
   only the two false secretkeeper notes fixed since (not rebuilt after that one-file fix).
5. **Later:** CI files in the repo (TODO above); removing cache trees of kernel builds no longer
   used (`/var/cache/churro/src-<build>`, `kernel-*`, `packs-*`: one set per kernel build today).
6. **Docs.** docs/03 §2 and its "moving to a newer image" checklist point here (done); still to
   do: trim what this replaces there, README's updater section mentions the tested table.

## Open questions
- Other Googlebook models (lapis, moonstone, mica, quartz): untested; they may ship another
  kernel build at the same image build, which the two separate keys already allow. The tested
  table would need a device column.
- Decided: an image (or kernel) build newer than the newest tested one builds without asking,
  with a notice (`CHURRO_TESTED_BUILD`, `CHURRO_TESTED_KBUILD`); the checks decide.
