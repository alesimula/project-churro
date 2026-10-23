# 05 — Hardware support: status and roadmap

Goal: one generic image that boots on as many PCs as possible. This page tracks what each kind of
hardware needs, what Churro does today, and the planned next steps.

## ⚠ Safety: things that must stay disabled

The Googlebook image assumes it runs on a Googlebook and **updates firmware by itself, at boot,
without asking**. On any other PC each of these can damage hardware or lock you out of Windows:

| Image component | What it does on a Googlebook | Risk on a PC | Churro |
|---|---|---|---|
| `spi-intel.writeable=1` + flashrom/futility/vpd/crossystem/elogtool | rewrites coreboot, EC, VPD in the SPI flash | **bricked BIOS** | flag stripped, SPI drivers blacklisted, tools removed |
| `fwupd` + `fwupd_blocking_update` (every boot, `ApprovalRequired=false`, LVFS enabled) | updates touchscreen, camera, USB-hub firmware | reflashes any matching SSD, hub, dock, camera, Thunderbolt controller | removed |
| `gscutil`, `check_tpm_clear` (every boot, `/dev/tpm0`) | updates / resets the Google security chip | sends vendor/clear commands to the PC's TPM → **BitLocker recovery, lost TPM keys** | TPM drivers blacklisted (the tools find no TPM) |
| `efi_pstore` (built into the GKI kernel) | saves the kernel log into UEFI variables on every panic | fills the PC's NVRAM → some firmwares stop booting | `efi_pstore.pstore_disable=1` always on the cmdline (found via the GBRUNCH comparison, docs/06) |
| vendor fstab `voldmanaged` entries: `/devices/*/nvme/nvme[1-9]*`, `/devices/*/mmc_host*`, `/devices/*/usb*` | SD card / USB sticks as storage | Android mounts (rw) or offers to *format* a PC's second NVMe or internal eMMC holding Windows; already mounts our own boot stick's CHURRO-LOG | **DONE** — `firmware-lockdown` removes the `nvme` and `mmc_host` lines (only `usb` stays: sticks, external drives). Internal and secondary disks are never auto-mounted; this is what made adding the VMD driver safe |

Rules: these protections are in `churro.sh` and the default `firmware-lockdown` feature, and there
are deliberately no switches to undo them. Anyone changing this must re-check the vendor and
system init scripts for new updaters with each new Googlebook image (`grep -rE
'flashrom|futility|fwupd|gsc|tpm|crossystem' */etc/init`).

## Hard floor: the CPU

Googlebook userspace is compiled with `-march=pantherlake` (seen in
`dalvik.vm.isa.x86_64.variant=pantherlake`), so the compiler emits recent instructions
**unconditionally** — not behind runtime CPU checks — into core binaries including `init`, `fs_mgr`
and `libinput`. An ELF scan of the image (~3100 files) found baked in everywhere: AVX2/BMI2/MOVBE/FMA
(hard floor = Haswell, ~2013), GFNI (271 files, incl. `init`), AVX-VNNI VEX (init + ~108 files), and
**AVX-IFMA VEX** — emitted by the Rust float formatter (`zmij`), so it lands in libinput,
libinputflinger and other core libs. All Intel Googlebook images share this one build (the other two
targets are ARM/Snapdragon). A CPU missing any of these faults with `#UD` in a core process → panic.
SHA-NI/VAES/VPCLMULQDQ/ADX are mostly BoringSSL, whose CPUID checks `-march=pantherlake` turns into
compile-time "yes" (rebuilt by `crypto-generic`, below); the AVX-512 EVEX hits are dispatched.

**This corrects the earlier "12th gen (Alder Lake) is fine": AVX-IFMA VEX is missing on
Alder/Raptor/Meteor Lake too**, so the true native floor is ~Arrow Lake / Lunar Lake / Panther Lake
(+ AMD Zen 5). Running below it means either trapping the missing instructions (a kernel `#UD`
handler) or rewriting the binaries offline. A trap handler is **dormant on a CPU that has the
instructions** — zero cost on the MSI.

Seen on real hardware: HP AiO (older Intel) → `init trap invalid opcode` → panic; Asus T300FA
(Broadwell) won't boot; Asus VivoBook 15 (i7-1165G7, Tiger Lake) → `{vex} vpdpwssd` (AVX-VNNI) in
second-stage `init` → panic.

| CPU class | Missing vs. the image | To boot |
|---|---|---|
| Arrow/Lunar/Panther Lake, AMD Zen 5 | nothing | boots as-is (the MSI) |
| Ice/Tiger/Rocket Lake, AMD Zen 4 | AVX-VNNI VEX + AVX-IFMA VEX (Zen 4: none) + SHA-NI (Ice/Tiger) | emulated in-kernel on `#UD` |
| Alder/Raptor/Meteor Lake | AVX-IFMA VEX only (they have AVX-VNNI) | emulated (only the 2 IFMA ops trap) |
| Haswell → Comet Lake, Zen 1–3 | + GFNI, SHA-NI, 256-bit VAES/VPCLMULQDQ (BoringSSL, compile-time on); Haswell also ADX | all 23 emulated; GFNI sits in hot loops (libyuv), VAES in AES-GCM → real perf cost |
| pre-Haswell; Atom without AVX | AVX2/BMI2, everywhere | not feasible |

Plan (implemented): a kernel `#UD` handler (`kmod/patches/vex-emulate.patch`, built from
`tools/vexemu/generate_traps.py`) emulates the 23 instructions userspace hits on a gap CPU:
AVX-VNNI `vpdpbusd(s)`/`vpdpwssd(s)`, AVX-IFMA `vpmadd52l/huq`, GFNI
`gf2p8affine[inv]qb`/`gf2p8mulb`, VPCLMULQDQ (VEX 128/256), 256-bit VAES
(`vaesenc/enclast/dec/declast` ymm), and the legacy-encoded SHA-NI set
(`sha1rnds4/nexte/msg1/msg2`, `sha256rnds2/msg1/msg2`, incl. the REX forms for xmm8–15 that
BoringSSL and liblzma use; legacy writes keep the upper YMM half), and ADX `adcx`/`adox`.

**ADX (Haswell).** The ASUS G20AJ (i7-4790) stalled in boot: `odsign` died with SIGILL every
5 s in `libcrypto.so` `bn_mulx4x_mont` (`adcx %rax,%r13`, reached from BoringSSL's lazy RSA
self-test in `RSA_verify`), and `init.rc` waits on `odsign.key.done`. ADX came with Broadwell;
the image has it in all libcrypto copies (358 sites each, RSA/ECC), Rust `ring` (520),
`libjavacore` (263), `libhpke_jni`, audio effects and cros_ml. `handle_adx_ud()` runs before the
VEX path and touches no FPU state (no xsave/xrstor): decodes `66|F3 [REX] 0F 38 F6 /r` (no
prefix = WRSS, rejected), dest += src + carry with the carry from/to CF (`adcx`) or OF (`adox`)
only, 32-bit forms zero-extended, register or memory source. Differential test vs. native ADX
(kernel decoder + extracted code, 9,000 random programs / 540,000 ops: 0 mismatches; mutations
of carry-in, 32-bit truncation, CF/OF choice, flag preservation and REX.B all caught) and
vextest `adcx/*`, `adox/*`. No run-ahead for integer code yet: measure the trap counts first. Measured (G20AJ, 2026-10-23, data-kept boot with Play updating apps): 10.5-11.8 M adcx/adox traps from `libjavacore.so`'s own *statically linked* BoringSSL (APK signature verification in Java crypto) — `crypto-generic` replaces the shared libcrypto copies, not this one, so the "adcx 0" of the earlier light session was workload, not coverage. Correct, and the C path handles it; a hot session like this is the case for integer run-ahead if it ever bothers.

**Run-ahead (SHA-NI cost).** First T300FA boot (Broadwell): 1.87 billion traps in 19 min, ~2.3 M/s
sustained = the whole CPU; 93 % SHA-256, from processes like `cp`/`mv`/`log` (toybox links
libcrypto, whose constructor runs BoringSSL's FIPS integrity check = SHA-256 over its own code, in
every process). BoringSSL's SHA-NI loop is 56 SHA ops per 64-byte block interleaved with plain
SSE, so after a trapping SHA op the handler now keeps interpreting the straight-line code that
follows (`churro_ra_step`): an exact allow-list (`movdqa`/`movdqu` loads + reg moves, `paddd`,
`pshufd`, `palignr`, `pshufb`, `punpckl/hqdq`, SHA-NI, `lea r64,m`, nops; one 66/F3 prefix, REX),
on copies of the XMM low halves and GPRs, written back once. Anything else ends the run and the
CPU executes it natively: stores, branches, flag-setting ops, VEX, segment prefixes, a load that
would fault or a misaligned `movdqa` (#GP), single-stepping (`TF`); max 256 per trap. On the real
libcrypto block it covers 55 of 56 SHA ops (stops at the loop's `dec`): ~2 traps per block
instead of 56. `churro.vexemu_runahead=0` turns it off; the dmesg trap line shows `+N run-ahead`.
**VEX run-ahead (AVX-VNNI loops) + native `vpdpwssd` (2026-10-22).** The same idea for VNNI loops
(the SIMD Adler-32 statically linked in AppSearch's `libicing_anywhere.so`, codecs, RenderEngine):
after an emulated VNNI instruction the handler interprets the following allow-listed VEX code
(`vmovdqu/vmovdqa` loads, `vpxor`, `vpaddd`, `vpmaddwd`, `vpsadbw`, `vpmaddubsw`, the four VNNI
ops, `lea`, nops) *inside* the `fpregs_lock()` window, executing each instruction natively on
full 32-byte register copies — `vpdpwssd` itself as `pmaddwd`+`paddd` (AVX2 = the image's floor).
Memory operands and the instruction fetch use non-faulting copies (`pagefault_disable()` +
`__copy_from_user_inatomic()`), so a fault just ends the run and the CPU faults on the real
instruction; a VEX.128 write zeroes the upper half like hardware. Stores, branches and
flag-setting code end the run, so the loop's `inc/cmp/jne` is the natural stop: ~1 trap per
128-byte Adler-32 iteration instead of 8. Gated on AVX2+SSSE3 and `churro.vexemu_runahead`;
dormant on CPUs with VNNI (Alder Lake+, Zen 5, the MSI).
Validated by a differential test (kernel decoder from `tools/` + the extracted run-ahead code vs.
native execution of 10,000+ random allow-listed programs on Arrow Lake: 0 mismatches; mutations of
paddd/palignr/pshufb/REX/alignment all caught) and vextest `runahead/sha-chain` +
`runahead/vex-chain` (a two-run chain: load/shuffle/VNNI mix, a run-stopping `add`, a memory-form
and a VEX.128 VNNI; the model is verified natively on Arrow Lake first). GFNI and SHA land here because
`init`'s libcrypto (AES key schedule) and BoringSSL's FIPS module check (HMAC-SHA-256) run
them unconditionally; `vpclmulqdq` likewise via AES-GCM, and `vaesenc ymm` via the FIPS
self-test (`libcrypto.so` from second-stage `init`: SIGILL right after first stage on the
T300FA's Broadwell; Tiger Lake has VAES natively, so it never showed there). Ice/Tiger Lake native-set also lacks
256-bit PCLMUL. The handler decodes the trapping instruction with the kernel's insn decoder,
resolves register (incl. VEX R/X/B-extended and ModRM/SIB/RIP-relative memory) operands against
the task's xstate (YMM handling aware of INIT-state zero upper halves), computes the exact
semantics (hardware-validated; the saturating VNNI forms saturate the final s32 accumulate,
confirmed against native silicon), writes back, and advances RIP. Per-opcode ratelimited
trap counters in dmesg are the hotness gauge for a later offline rewriter. Default on;
`churro.vexemu=0` in bootconfig restores the plain SIGILL. Dormant on CPUs with the native
forms (handler only fires on `#UD`).
**Native AES/CLMUL fast path.** 256-bit `vaesenc`/`vaesenclast`/`vaesdec`/`vaesdeclast` and
`vpclmulqdq` are the 128-bit AES-NI / PCLMULQDQ instruction once per lane; on any CPU that has
those (`X86_FEATURE_AES` / `X86_FEATURE_PCLMULQDQ`: Intel Westmere+, AMD Bulldozer+) the emulator
runs them natively on its operand copies (inside the handler's `fpregs_lock()` window, where the
task's FPU state is saved and reloaded and no other kernel FPU user can run), else the C model
(S-box + GF(2^8) MixColumns, bitwise carryless multiply). The trap itself still costs; this cuts
the per-instruction work, which on the T300FA throttled TLS downloads (AES-GCM) to ~270 KB/s.
vextest: `emu` exercises the fast path, `emu-c` (no AES-NI/PCLMULQDQ) the C fallback.
Perf note: GFNI also lives in libyuv hot loops (Tier 2, ~271 files) — emulation there is
correct but slow; a real perf-cost class remains for Haswell → Comet Lake / Zen 1–3.
Validation: `tools/vextest` (hand-encoded register/SIB/RIP-relative/imm cases vs scalar
reference, a 512-block chained sha256rnds2-vs-textbook-SHA256 oracle, and
chained-accumulate/multiprocess streams): all pass natively on the MSI and on a gap QEMU CPU
(`Icelake-Server` TCG, where TCG genuinely lacks these) fully emulated; `churro.vexemu=0`
makes the same initramfs die with SIGILL on the first instruction, proving the kill switch.
Dev-only files (not used by `churro.sh` or the kernel build, which only applies the patch):
`tools/vexemu/generate_traps.py` rebuilds `tools/vexemu/traps.c`, a readable reference copy
of the patched `traps.c`, from a pristine `out/traps.c`. Edit the emulator there, regenerate,
then diff against `out/traps.c` to refresh the patch. `tools/vextest/run.sh build|native|qemu`
builds and runs the test binary; `diaginit.c` is a tiny initramfs probe that shows which
output channel (kmsg/ttyS0/console) reaches the QEMU serial log.
Caveats: (a) QEMU TCG itself miscomputes chained ymm accumulators even without emulation
(also reproducible with TCG-natively translated `vpmadd52luq`), so TCG full-image boots are
only used for unit tests, not as a correctness reference; (b) real-device (Tiger Lake)
validation is one boot sample reaching the setup UI, with GMS/ART dex issue still open —
see `boot.log` high `vpdpwssd` trap counts; performance on trap-heavy processes is limited.

**BoringSSL rebuilt (`crypto-generic`, phase 1: system + vendor).** BoringSSL picks its SHA-NI,
VAES, VPCLMULQDQ, ADX, ... code paths with `CRYPTO_is_*_capable()` (`crypto/internal.h`): CPUID at
run time, unless the compiler flags already promise the feature. Google's `-march=pantherlake`
promises all of them, so the image's libcrypto runs them unconditionally and old CPUs trap on
every SHA-256 / AES-GCM / RSA (the bulk of the T300FA and G20AJ trap counts: FIPS integrity check
in every process, TLS, `odsign`). `crypto/build-boringssl.sh` builds the same upstream source
(the version pinned by the image's exports, see the script) with Android's options (FIPS shared
module + integrity hash, `OPENSSL_SMALL`, `BORINGSSL_ANDROID_SYSTEM`, static hidden libc++,
`-Bsymbolic`) but `-march=x86-64-v3`: CPUID checks are real again, so Arrow Lake keeps every fast
path and Haswell/Broadwell run plain AES-NI/SSSE3/AVX2 code natively. Installed over
`/system/lib64` and `/vendor/lib64` `libcrypto.so` + `libssl.so` only if they export every
dynamic symbol the image's do (names, types, binding, data sizes; extra exports allowed, so a
newer pinned commit in `versions.env` can pass — struct layouts and behaviour aren't checked). The emulator (incl. the AES/CLMUL
fast path) stays for everything else. G20AJ: `odsign` 89.8 s → 0.37 s, setup screen 4:02 → 2:08
(docs/02). The copies inside signed APEXes (Java crypto, TLS, Wi-Fi, Bluetooth):

- **Phase 2a — platform libcrypto/libssl in APEXes.** 11 APEXes carry their own copy, all with
  exactly the system library's exports, so the `crypto-generic` build drops in unchanged:
  Conscrypt (`libcrypto` + `libssl` + `boringssl_self_test64`), Tethering, Wi-Fi,
  ConfigInfrastructure (`libcrypto` + `libssl`), Bluetooth, adbd, OnDevicePersonalization
  (`libcrypto`); vendor: ClearKey DRM, crosfp fingerprint, StrongBox KeyMint (disabled; + `libssl`
  for the last two). virt/compos only link to it. **Done without touching the APEXes**:
  `features/crypto-generic/system/system/etc/init/churro-apex-crypto.rc` bind-mounts our
  `/system/lib64` (system APEXes) or `/vendor/lib64` (vendor APEXes) files over each copy in
  `on post-fs-data`, which runs after init.rc's (apexd has activated everything, init is in the
  default mount namespace) and before zygote and the HALs, which inherit the mounts. The signed
  APEX files and their verification stay as Google shipped them; StrongBox KeyMint (disabled) is
  left out. SELinux (enforcing) denied init `mounton` on these files (`system_lib_file`,
  `system_file`, `vendor_file`): `crypto-generic`'s `patch-vendor.sh` adds exactly those three
  allow rules to the vendor policy (compiled on-device).
- **Phase 2b — `libcrypto_httpengine.so`.** One copy, in the Tethering APEX (HttpEngine = platform
  Cronet). A different BoringSSL: Cronet's bundled one (`external/cronet/stable/third_party/boringssl`,
  Chromium's version pin), 324 exports with `@@INTERSECTED_SYMBOLS` versions (vs. 2695). Needs its
  own version search, build options and export gate; installed with a bind mount as in 2a.
  **Built** (`crypto/build-boringssl-httpengine.sh`, from `patch-system.sh`): the image's
  `libhttpengine.so` is Chromium 150.0.7871.41, whose DEPS pins BoringSSL `3a9254f16`
  (`BORINGSSL_HTTPENGINE_REV`). Must be that exact commit: the 323 exports include internal C++
  helpers (`bssl::Mutex`, `spake2plus::Prover`, `OPENSSL_lh_*`, refcounts on `std::__Cr::atomic`)
  whose layouts libhttpengine was compiled against. Built like AOSP does: static libcrypto with
  default visibility, linked into a shared object exporting exactly the image's symbols under
  `INTERSECTED_SYMBOLS` (version script generated from the image's library), compiled in
  Chromium's libc++ namespace `std::__Cr` with the NDK's static libc++ kept local
  (+ a `__libcpp_verbose_abort` → abort shim); `OPENSSL_SMALL` like Chromium on Android; not FIPS.
  Installed as `/system/lib64/libcrypto_httpengine.so`, bind-mounted over the APEX's copy.
  **Confirmed on the G20AJ**: AES-GCM traps 0 during setup, Play downloads/installs, Chrome,
  Firefox, Reddit; 300 M traps in 12.5 min instead of 740–810 M (docs/02; one earlier run showed
  no change, possibly still the previous image).
  Why it matters (G20AJ after 2a): the remaining 488 M AES-GCM traps (60 %) are 256-bit VAES in
  `CronetNet` threads, which only a Panther-Lake-compiled copy executes on Haswell; the
  app-bundled Cronets (GMS CronetDynamite, Play Store's libcronet) dispatch by CPUID.
  Earlier estimate: on the G20AJ, TLS-style traps (`vaesenc`/`vaesenclast`/`vpclmulqdq`) were
  ~25 % of all traps in 20 min (361 M of 1.43 billion), mostly `CronetNet` and `dl.google.com`
  threads (Play/GMS downloads), but the trap log names the thread, not the library: that could be
  HttpEngine, the Cronet GMS bundles itself (not replaceable), or Conscrypt (2a). To decide
  first: add the faulting address's mapped file (VMA file name) to the emulator's ratelimited trap
  line, which also locates the `vpdpwssd` hot spots below.

**`libz.so` and bionic (libc, libm, linker) from the emulator image (`libs-generic`, confirmed on
hardware: G20AJ + T300FA).** After 2a/2b, `vpdpwssd` was 99 % of the remaining traps on the G20AJ
(296 M in 12.5 min), mostly `libz.so` (zlib's Adler-32/CRC); on the T300FA the top sources were
bionic `libc.so` (GFNI, 2570 sampled lines in 40 min), `libz.so` (699), `libart` (435),
`linker64` (375). Instead of a source rebuild, Google's x86_64 emulator image of the same Android
release (already downloaded for the software KeyMint, `lib/emu-image.sh`) donates generic
x86-64 builds of the same files: no GFNI/VNNI/VPCLMULQDQ/AVX-512, not even AVX2. Checked per
file at build time: every dynamic symbol (name + version) the image's file exports must be
exported by the donor (libc 1474, libm 286, linker 29, libz 99: identical sets), and the donor
must use no instruction a Haswell lacks; otherwise the image's file stays (logged). Copies
handled: `/system/lib64/libz.so`, `/vendor/lib64/libz.so` (emulator vendor build), the bionic
bootstrap set in `/system/lib64/bootstrap` + `/system/bin/bootstrap/linker64` (init and the
processes before APEXes are mounted), and the `com.android.runtime` APEX as a whole file
(identical `apex_manifest.pb` and file list; `libdl`/`libdl_android` are byte-identical in both
builds; libc and the linker always come from the same build). Other `libz.so` copies: the face
HAL APEX (removed by `security-software`) and arm64 guest copies (translator, not run natively).
Donor build is older (CE2A.260420, userdebug) than the image (CL3B.260622): same release, same
exports, but not the same day's source; no regressions seen on hardware (276.R4 image). Image scan (2423 x86-64 ELF
files): 323 contain instructions Haswell lacks; static counts overstate (much is CPUID-dispatched:
OpenVINO, libjxl's AVX-512); the trap log is the guide. Next by trap count: ART (`libart`,
`libartbase`: Play-updatable APEX, left alone), Rust `libstd.dylib.so` (system, vendor, APEXes),
`libhwui` (101 of the 121 affected system-partition files exist at the same path in the
emulator image).
Result: `libz.so`, `libc.so` and `linker64` no longer show up in the trap log. G20AJ: `vpdpwssd`
140 M in 5.7 min → 0 in 7 min, `gf2p8affineqb` 2.2 M → 0.6 M. T300FA: `vpdpwssd` 124 M in 11 min →
0.8 M in 31 min (left: `libicing_anywhere`), boot animation 95–106 s → 36 s, boot completed
75–92 s → 48 s. Left on both: `gf2p8affineqb` in `libart`/`libartbase`/`libhwui`/`libstd.dylib`.

**`vpdpwssd` (AVX-VNNI) cost — mostly solved by `libs-generic`** (it was mainly `libz.so`: now G20AJ 0,
T300FA 0.8 M in 31 min; notes below kept for what remains). Was the biggest non-crypto trap source on gap CPUs (G20AJ: 226 M
in 15 min; VivoBook: 136 M per boot), compiler-generated across ~108 files (Skia/HWUI/RenderEngine
`TextureLoadThread`, app RenderThreads, ART Profile Saver/dex2oat): not rebuildable like
BoringSSL. The ratelimited trap lines end in `@ <file>(<fs id>)+0x<file offset>` (vexemu
`churro_where()`), so the hot libraries are known: after `libs-generic` the G20AJ's remaining
~1.2 M traps / 7 min are `vpdpwssd` 0.7 M (essentially all in AppSearch's statically linked SIMD
Adler-32, `libicing_anywhere.so`: one loop, 128 bytes/iteration, all VEX.128) plus GFNI in
ART/HWUI/Rust — under 1 % of one core, so the options below are done for completeness, not need:
1. Native fast path (**done**, 2026-10-22): `vpdpwssd` = `pmaddwd` + `paddd` on the operand copies
   inside the handler's `fpregs_lock()` window, like the AES/CLMUL fast path; AVX2 is the image's
   own floor, so it is always available. The C model stays for `vpdpbusd(s)` and the saturating
   forms (no native equivalent: `pmaddubsw` saturates per word).
2. VEX run-ahead (**done**, 2026-10-22): after an emulated AVX-VNNI instruction, interpret the
   following straight-line VEX code — allow-list `vmovdqu`/`vmovdqa` loads, `vpxor`, `vpaddd`,
   `vpmaddwd`, `vpsadbw`, `vpmaddubsw` and the four VNNI ops, plus `lea` and nops; anything else
   (stores, branches, flag-setting ops, other maps/prefixes) ends the run and the CPU executes it
   natively. Unlike SHA's run-ahead (C model on XMM low halves, after the lock) this runs *inside*
   the `fpregs_lock()` window, so every allowed instruction executes natively on full 32-byte
   register copies — the design point the SHA version couldn't reach: memory operands and the
   instruction fetch use non-faulting copies (`pagefault_disable()` +
   `__copy_from_user_inatomic()`), and a fault just ends the run so the CPU faults on the real
   instruction instead. A VEX.128 write zeroes the upper half, like hardware. On the Adler-32
   loop a run covers the rest of the iteration (its leading loads and shuffles are all
   allow-listed) and stops at the loop's flag-setting `inc/cmp/jne`: ~1 trap per 128 bytes
   instead of 8 (~8×; SHA got 28× because its loop is fully unrolled). Gated on AVX2+SSSE3 and
   `churro.vexemu_runahead`; dormant on CPUs with VNNI. Confirmed on the T300FA: `vpdpwssd @
   libicing_anywhere.so (+35 run-ahead)` per trap (main loop; +4 on the 2× tail), 210 677 traps
   in 64 min vs 0.8 M in 31 min before = ~8× fewer, no native crashes.
3. Offline patching of the hottest call sites (replacement needs a scratch register and more bytes
   than the original → trampolines): removes the traps, riskiest, still last resort — changes
   binaries for everyone.
Also noted (not taken): the emulator image's AppSearch APEX has a generic `libicing_anywhere.so`
(no AVX2 at all), but it is an older build (one JNI method less): swapping the whole APEX would
remove the remaining source at the root, yet downgrade a Play-updatable module — only worth it if
a trap log shows it hot again (the T300FA is the machine to check: 2C/4T at 0.8 GHz).

Not fixable this way: BoringSSL bundled inside apps (e.g. GMS's own Cronet, if that's what
`CronetNet` threads use); the emulator keeps handling those.

brunch (docs/06) does none of this: it selects a prebuilt image per CPU family and declares
older CPUs unsupported.

## GPU

| GPU | Today | Next |
|---|---|---|
| Intel iGPU / Arc (Gen12+) | image's own `xe` + `firmware-extra` (GuC/HuC/GSC/DMC from linux-firmware); default graphics = Google's stack (ANGLE on ANV); hwcomposer color pipeline off; allocator rebuilt (`gfx-minigbm`): any Xe GPU, by graphics IP version | — (Arrow Lake verified on the MSI) |
| Intel pre-Gen12 | our `i915` via `drivers-extra` (vendor_dlkm, linked to Google's `drm_display_helper`; aliases minus the 139 IDs `xe.ko` binds, so it only loads where `xe` can't) + Mesa `iris`/`crocus`; boot menu picks `mesa` for them | needs the `#UD` emulator (Haswell…Ice Lake CPUs). Gen4–8 primary planes have no alpha formats → `i915-gen4-primary-alpha.patch` (ARGB/ABGR scanned out as X formats, else the desktop is black). T300FA: setup renders, desktop fix to verify |
| AMD | amdgpu module + firmware (distro module set); no userspace yet | Mesa radeonsi/radv + allocator backend + GRUB detection |
| NVIDIA | `gpu-nouveau` (below): nouveau display + GSP firmware + allocator with VRAM buffers; GL = Zink on NVK (Kepler+) or nouveau GL (older), Vulkan = NVK; only where nothing else drives the display | MSI discrete mode (RTX 5070 Ti, GB205) works: panel + HDMI, Chrome (NVK AHB patch); hybrid machines: NVIDIA unused (HDMI wired to it stays dark) → reverse PRIME / render offload |
| No usable GPU | no UI: no allocator backend for simpledrm/vgem, and Mesa's software path needs llvmpipe (LLVM) to import buffers | fallback allocator backend + llvmpipe |
| VMs (QEMU) | virtio-gpu in the `gpu` pack; vgem loaded by `gfx-soft.rc` (not on machines with a GPU: it would take renderD128) | — |

The graphics stack is picked at boot (`--gfx auto`, the default): GRUB reads PCI config space -
an Intel iGPU at 00:02.0 (hybrid laptops included) → `native` if the image's `xe.ko` binds its
device ID, `mesa` (our i915) if not; else an NVIDIA display controller → `nouveau`; else `soft`.
The ID list comes from `xe.ko` at build time (drivers-extra → `CHURRO_XE_IDS` → a `regexp` in
grub.cfg); without it every Intel iGPU gets `native`. A GRUB menu entry or an explicit `--gfx` wins.

**Why i915 is safe next to xe now** (it caused the MSI regression as a first-stage pack, docs/02):
that pack loaded on every machine, claimed Gen12+ GPUs before `xe` (i915 lists 109 of the 139 IDs
`xe` binds) and brought its own `drm_display_helper`, which lacks the vendor backports `xe` needs
(`drm_dp_cec_*`, `drm_dp_dsc_sink_slice_count_mask`). Checked offline with depmod against the
image's modules: our i915 links against **Google's** `drm_display_helper`/`drm_buddy`/`video`/
`wmi`/`i2c-algo-bit` with no unknown symbols or CRC mismatches (adds only `intel-gtt`, `hwmon`),
while swapping in our `drm_display_helper` reproduces the MSI's `xe` errors. drivers-extra never
replaces a Google module with one that exports less, so `xe` keeps Google's. The minigbm
`xe-unknown-gpus` fix is unaffected: every GPU `xe` binds stays on `xe`.

**`soft` only works in VMs today.** Confirmed on the T300FA (no i915 loaded): with
`androidboot.churro.gfx=soft`, `gfx-soft.rc` is imported but `vendor.graphics.allocator` and
SurfaceFlinger fail with `Failed to initialize driver` in a loop. Our minigbm build
(`gfx/build-minigbm.sh`) has no backend for the only DRM devices left, `vgem` (renderD128) and
`simpledrm` (card0): `drv_backend_list` covers i915/xe + the dumb drivers (evdi, udl, vkms, …),
and `vgem`/`simpledrm` are not among them. In QEMU the virtio-gpu backend is used instead,
which is why it worked there. Worth keeping for debugging and GPU-less machines: the fix is a
`gfx/minigbm-patches/` patch adding `INIT_DUMB_DRIVER(vgem)` (+ `simpledrm`) to `dumb_driver.c`
/ `drv_backend_list`, tried **only as a last resort** in `cros_gralloc_driver.cc`
(`init_try_nodes`). vgem is now loaded only by `gfx-soft.rc`, so it no longer takes renderD128
from the real GPU (that broke hardware video decoding, "Known gaps"). Then check Mesa's
kms_swrast/llvmpipe can map those buffers (the row above).

**Gotcha when testing `soft` by hand:** the main GRUB entries append the auto-detected `$gfx`
last, and Android keeps the *first* `androidboot.churro.gfx=` value (`Init cannot set
'ro.boot.churro.gfx' … already set`). Replace `$gfx` in the edited `linux` line rather than
adding a second value after it.

## Other hardware

| Area | Today | Next |
|---|---|---|
| Storage | NVMe/USB built in; `storage` pack (first stage, so all bootable): AHCI (SATA, M.2 SATA), `ata_piix`/`ata_generic` (BIOS SATA in IDE mode), Intel VMD (RST/VMD mode), eMMC (sdhci-pci/acpi) | RST "Optane/NVMe remapping" (no Linux driver: switch BIOS to AHCI). Secondary internal disks and SD cards aren't mounted in Android (safety, above: SD shares the `mmc_host` line with eMMC); no NTFS in the kernel |
| Intel Wi-Fi / BT | image's iwlwifi/btintel + `firmware-extra` (modinfo-declared names + name templates for Bluetooth) | MSI (AX211, `so-a0-gf-a0-89`) works. VivoBook 15 (AX201, Qu): Google's iwlmvm unmaps RX buffers the IOMMU never mapped (WARN storm, firmware crashes, downloads stall) → `churro.sh` always sets `iommu.passthrough=1`; Bluetooth `ibt-1040-0041` unverified |
| Other Wi-Fi / BT | distro module set: ath9k/10k/11k/12k, rtw88/89, rtl8xxxu, mt76, brcm, … + their firmware + regulatory.db; they link against the image's cfg80211/mac80211 (CRCs match ours, so the ABI check accepts them) | verify on hardware; the opt-in `wifi` pack is probably obsolete |
| Ethernet, USB devices, card readers, touchpads/touchscreens, sensors, HID | distro module set (`drivers-extra`, ~3000 modules, loaded by device alias) | test on more machines |
| Audio | HDA + SOF from the image + distro codec/amp drivers; SOF firmware/topologies (sof-bin, merged per file), amp tunings via WHENCE; `audio-generic`: board audio cmdline/blocklist/options removed, codec drivers preloaded, HAL config for HD-audio cards (`PCH`, `Generic*`, `Intel`, `sofhdadsp`) bind-mounted over Google's board config, card renamed to the board's ID; works in QEMU (playback reaches the backend) | verify on MSI (speaker, headphones, mic, HDMI). Not covered: see "Known gaps" below |
| Modules left out | ~50 the ABI check rejects: some need exports Google's GKI modules trim (usbnet, usb-serial, ptp, nfc, rfkill helpers) or Google built a dependency differently (a few HDA/SoundWire codecs) | ship our builds of those GKI modules too |
| NPU (`intel_vpu`) | blacklisted (`CHURRO_NPU=false`): froze Arrow Lake | with `firmware-extra` the NPU firmware may now be there → retry with `CHURRO_NPU=true` |
| BIOS flash | always inaccessible (`firmware-lockdown` + cmdline + SPI driver blacklist) | — |
| Device firmware (SSD, hubs, cameras…) | `fwupd` removed (`firmware-lockdown`) | — |
| TPM | drivers always blacklisted: the image's gscutil/check_tpm_clear would talk to the PC's TPM (BitLocker!) | — |
| Security chip | not needed (`security-software`) | — |

## Known gaps (to implement)

**No Vulkan on pre-Gen12 Intel → camera HAL and Chrome fail** (T300FA, docs/02). The `mesa`
stack sets `ro.hardware.vulkan=none` unless `androidboot.churro.vulkan` is given. Google's USB
camera HAL panics without a Vulkan device (`desktop_camera_common::gpu::vulkan::is_supported`:
`no Vulkan physical device`, it panics instead of returning false), and Chrome 155 gives up
on the GL-only path (`GPU process isn't usable`). Done (camera works on the T300FA): `gfx-mesa` always
installs Mesa's `hasvk` and writes its GPU IDs (Mesa's tables: ivb/byt/hsw/bdw/chv, 93 IDs);
GRUB adds `androidboot.churro.vulkan=intel_hasvk` for those (Gen7–8: Ivy Bridge, Haswell,
Broadwell) and `=intel` (the image's own ANV, Mesa 26.1.3, has the Skylake+ tables and the i915
backend) for the other pre-Gen12 Intel GPUs (Gen9–11: Skylake..Ice Lake, untested: no such
machine here); Gen12+ keeps Google's stack. hasvk has AHardwareBuffer support built in (unlike
NVK upstream). On Haswell Mesa logs "Haswell Vulkan support is incomplete". T300FA result:
Vulkan found, but hasvk reports Vulkan 1.1 on Android (strict mode) and the camera HAL needs
1.2+ → `gfx/mesa-patches/hasvk-android-api-version.patch` (1.3 on Gen8, 1.2 on Gen7, as on
Linux) → camera streams. Still open: Chrome on ANGLE-Vulkan restarts its GPU process
(`CreateSharedImage: could not create backing` → context lost; 15× in 40 min with 1.3, 111× in
10 min with 1.1), not tied to GPU hangs; which buffer fails isn't logged.

**`timberslide` crash loop on every PC** (docs/02): the ChromeOS EC log daemon
(`/system/etc/init/timberslide.rc`, `class core`) exits at once without an EC and restarts every
~5 s; as an updatable process each crash runs `flags_health_check`, which resets
server-configurable flags (hundreds of times per session), and apexd tries reverts. Done (not
built yet): `features/firmware-lockdown/patch-system.sh` deletes the rc (timberslide only reads
the EC console log; its binary stays, unused).

**Bluetooth headset (HFP) audio: SCO packet size mismatch** (T300FA, AR3012). With `bt_wbs=on`
the stack expects 60-byte SCO packets (mSBC), the controller sends 72 (CVSD over USB alt
setting 3): every packet dropped (3520 in one call), and closing SCO preceded one controller
`Hardware Error 0x35`. Music (A2DP) not affected. Likely fix: no wideband speech for controllers
without the mSBC USB alt setting (per-controller quirk); to check after btcoex.

**`libz.so` / libc traps** — fixed by `libs-generic` (above, "`libz.so` and bionic"); T300FA boot
animation 95–106 s → 36 s. Left: GFNI in ART, `libhwui`, Rust `libstd`.

**APEX updates vs. the BoringSSL bind mounts** (`churro-apex-crypto.rc`). The mounts target
`/apex/<name>/lib64/...`, i.e. whatever version of the module is active. If a Google Play system
update installs a newer Conscrypt/Tethering/Wi-Fi/... APEX, our library (built for the image's
version) is mounted over the updated module's copy: missing exports make that module fail to
load, a changed internal layout (httpengine) crashes its users — zygote preloads libhttpengine.
Not seen yet. Fix before relying on it: mount only over the factory version (e.g. a small
helper that checks `/apex/apex-info-list.xml` `isFactory` before mounting), or block mainline
APEX updates together with `update_engine` (Open item "OTA updater").

**Video frames on nouveau GL (G20AJ, GM204): EGLImage import fails.** Firefox plays videos
black (its GPU process: `error creating EGLImage: 0x3000`); Reddit aborts after a while in HWUI
(`skia: Could not create EGL image, err = (0x3000)` → `AutoBackendTextureRelease.cpp Invalid
GrBackendTexture` → SIGABRT in RenderThread). Around them the software H.264 decoder logs
`C2SoftAvcDec: fetchGraphicBlock for Output failed` (only after the app died: `BR_DEAD_REPLY`).
Cause (from Mesa's source): decoder output is multi-planar YUV, one BO with the chroma plane at
an offset; Mesa imports each plane as a dma-buf with that offset, and nouveau GL's
`nouveau_screen_bo_from_handle()` rejects any offset ≠ 0. Android's EGL path then returns
`EGL_NO_IMAGE` without setting an error, hence `0x3000` (`EGL_SUCCESS`). **Fix (confirmed on the
G20AJ; now only used on Fermi and older, the rest runs Zink):** `gfx/mesa-patches/nouveau-import-plane-offset.patch`: import the BO at offset 0 and
point the resource at the plane (`address`/`offset`, which texturing, render targets, transfers
and the 2D engine already honour). nvc0 (Fermi-Ampere) only; Tesla's 2D path not adjusted. Zink
on NVK is not affected (Vulkan takes plane offsets).

**Fruit Ninja freezes the UI on the G20AJ (GM204, nouveau GL).** The app's HWUI channel takes a
copy-engine fault `UNSUPPORTED_KIND` (writing a buffer whose memory kind the engine can't handle),
the kernel kills it, SurfaceFlinger's channel faults right after on a missing page (the dead
app's buffer) → whole screen frozen. Another run: SIGSEGV in Mesa nouveau under Unity's draw
calls. Ruled out by experiment: compression (faults continued with it off in nvc0) and VRAM
pressure (no buffer ever left VRAM, per a temporary eviction log); faults also hit Play Store,
GMS's WebView and Gboard. **Fixed** by GL through Zink on NVK instead of nouveau GL: zero faults,
game runs (`gfx/mesa-patches/nouveau-zink-from-kepler.patch`, Kepler and newer). Remaining app
closes in that test were Google Play services' module updates (docs/02), not GPU problems.

**Hardware video decoding (Intel, `native`): every decode failed.** VivoBook (Tiger Lake, xe):
YouTube in Firefox loads forever, Reddit videos don't play, Camera can record but not play back.
Google's decoders (`c2.cros-codecs.vaapi.*`) opened `vgem` (`vgem_drv_video.so` → -1) and failed
(`returned error: 0x16`, 104 of 104 times): the codec service's other threads try the next
render node, but the decoder thread opens only `renderD128`, which `vgem` took by loading in first
stage before `xe`. Recording worked because the encoder path tries the next node. Fix: `vgem` left
out of the `gpu` pack, loaded by `gfx-soft.rc` only (the one stack that needs it). Affects every
Intel machine on `native` (the MSI too).

**Audio** (`features/audio-generic`, docs/03). Covered today: HD-audio codecs on legacy
`snd_hda_intel` (`PCH`, `Generic`/`Generic_1`, `Intel`) and on SOF's generic HDA machine
(`sofhdadsp`). Not covered, each needs its own `mk` line in `patch-vendor.sh` and usually mixer
setup in `mixer_paths.xml` (the controls these codecs need to route sound, which HDA does on its own):
| Gap | Typical machines | What it needs |
|---|---|---|
| SoundWire laptops | recent premium Intel laptops (XPS / ThinkPad X1 class: RT711/RT1316, CS42L43) | card ID from `sof-soundwire`, PCM numbers and mixer controls per codec set (alsa-ucm-conf `sof-soundwire/*` is the reference) |
| Machine-specific SOF cards | cheap ES8336 laptops, NAU8825/RT5682 Chromebook-style boards | one config per machine driver (alsa-ucm-conf has them) |
| AMD ACP digital mics / SoundWire | AMD laptops (Ryzen 6000+) | speakers usually work via `Generic*` (HDA); the mic is a separate ACP card (`acp6x`, `acp63`, …) — a second input config |
| HDMI audio on a separate GPU card | hybrid laptops with HDMI wired to the dGPU (MSI), desktops with discrete GPUs | the HAL only uses the one internal card; HDMI on another card (`NVidia`, `HDMI`) would need a second card in the HAL or the external-device path |
| Unverified on SOF | — | internal mic PCM 6 and HDMI PCM 3–5 for `sofhdadsp` are from the standard topology, not tested; headphone/speaker switching relies on the kernel's auto-mute (Android shows no headphone state) |

**IOMMU passthrough (applied, all entries).** Google's cmdline keeps the IOMMU translating every
device except the iGPU (`intel_iommu=igfx_off`), which their pKVM setup needs and Churro doesn't
use (`pkvm=0`). On the VivoBook's AX201 their iwlmvm unmaps receive buffers that have no IOMMU
mapping (`iommu_dma_unmap_phys` WARN per affected packet), and the card's firmware crashes
repeatedly, so `churro.sh` adds `iommu.passthrough=1`: internal devices DMA untranslated, as on
most Linux installs; ports the firmware marks external (Thunderbolt/USB4) keep a translated
domain; no-op without an IOMMU; works on AMD. Trade-off: no DMA isolation of internal devices,
and the driver bug is hidden, not fixed. Narrower option if ever wanted: a kernel quirk giving
only Intel Wi-Fi an identity domain (the `igfx_off` mechanism), no kABI impact.

**Display colour (applied).** Google's composer defaults are tuned for the Lenovo panel: the image
sets `vendor.hwc.drm.force_color_mode=13` and `persistent_hdr=true` (+ the composer's log-gamma
LUT). The MSI's panel showed a colour cast, as GBRUNCH (docs/06) saw on theirs, so `gfx-mesa` now
forces SDR in build.prop: `force_color_mode=7`, `persistent_hdr=false`, `use_log_gamma_lut=false`
(image's lines deleted, ours appended, in place). If a panel ever looks wrong the other way, those
three lines in `features/gfx-mesa/patch-vendor.sh` are the knob.

## Machines tried

| Machine | CPU / GPU | Result |
|---|---|---|
| QEMU/KVM | host / virtio | boots to system_server; SurfaceFlinger crashes in softpipe (QEMU 2D virtio-gpu) |
| Asus T300FA | Core M-5Y10 / HD 5300 | not bootable (CPU floor) |
| Asus VivoBook 15 (X513EA) | i7-1165G7 Tiger Lake / Iris Xe | boots with the `#UD` emulator (slow: `vpdpwssd` traps); setup wizard Wi-Fi stalls fixed by IOMMU passthrough |
| HP AiO | older Intel | `init` invalid opcode (CPU floor) |
| MSI (Core Ultra 7 255HX) | Arrow Lake / RTX 50 (10de:2f18) | hybrid mode: boots and runs (xe + our allocator); discrete (MUX) mode: works on nouveau/NVK (panel, HDMI, Chrome); distro driver set: touchpad works; audio works (audio-generic + churro-mixer); colour cast → SDR props (gfx-mesa) |

## Design direction: distro-style driver coverage (steps 1-2 done: distro module set + firmware)

The image is already generic: "build time" only means files are baked in, nothing is probed on
the build machine. `firmware-extra` takes its list from *every* module in the image, so one image
carries firmware for all xe-supported Intel GPUs, ~30 Intel Wi-Fi variants, Intel BT, Realtek
NIC/BT. The goal is to extend this the way Linux distros do: ship most drivers, load only what
the hardware needs.

What makes it feasible:
- **Android already autoloads by device ID.** `ueventd` matches modaliases against the module
  alias table (the "Unable to find a module for acpi:…" lines in boot.log), like udev. A large
  module set can ship; each machine loads only matching modules — in second stage, so firmware is
  reachable (first stage can't see `/vendor/firmware`).
- **We build the kernel** with Google's KMI preserved, so almost any in-tree driver can be added
  as a module (amdgpu, nouveau, rtw88/rtw89, mt76, ath10k/11k, card readers, touchpads, codecs).
- **Size is fine:** modules are small; firmware for a broad set is a few hundred MB vs. an 8 GB image.

Where Android is harder than a Linux distro:
1. **Conflicting stacks.** Some drivers can't coexist: Google's Intel Wi-Fi runs on an
   out-of-tree cfg80211/mac80211 (iwl7000) that in-tree Wi-Fi drivers can't link against;
   i915 and xe need different `drm_display_helper` builds. Needs a **boot-time stack picker**:
   a small early step (the `rdinit` hook the logger already uses is the natural place) that reads
   PCI IDs and decides which stack gets loaded (Wi-Fi first, then graphics).
2. **HALs, not just drivers.** Linux userspace is generic (Mesa, PipeWire, NetworkManager);
   Android's graphics allocator/composer, audio, etc. are per device, and Google's are
   Intel-only. AMD/NVIDIA/no-GPU need the generic allocator + Mesa; unknown audio codecs need a
   generic audio HAL configuration. Android-x86 / Bliss OS solved this (minigbm/gbm_gralloc +
   drm_hwcomposer, generic tinyalsa audio) — known territory.
3. **More drivers = more chances one misbehaves** (cf. the NPU freeze). Safety valve: per-driver
   blocking via `module_blacklist` (already used), later exposed as a GRUB entry or setting.

Order:
1. Done: `kmod/profiles/generic.conf` takes Arch Linux's module set from driver directories
   (docs/03), `drivers-extra` installs it with an ABI check against the image's modules.
2. Done: `firmware-extra` covers them (modinfo names + every WHENCE file of a shipped driver +
   files matching name templates in the modules + sof-bin + wireless-regdb). Finding on the way: the image's cfg80211/mac80211 have the same CRCs
   as our build, so in-tree Wi-Fi drivers link against them (the Wi-Fi half of "conflicting stacks" above may
   not apply; to confirm on hardware).
3. Boot-time stack picker (Wi-Fi, then graphics; replaces build-time `--packs wifi` / `--gfx`).
4. Generic graphics allocator + Mesa CPU rendering, then AMD (amdgpu + radeonsi/radv) and
   NVIDIA (nouveau + NVK/Zink) on top.

None of this replaces what exists; each step is additive.

### Graphics allocator (`gfx-minigbm`)

Why it's needed even for Intel: Google's minigbm (`libminigbm_gralloc.so`, used by the allocator
service *and* the mapper loaded into every app; `libgbm.so`, used by the codec/camera HALs) only
accepts GPU IDs from tables compiled into it. Found on the MSI: `Xe driver is not supported on
your platform: 0x7d67` → every buffer allocation fails → SurfaceFlinger aborts. The tables cover
ADL/RPL, Meteor Lake, Lunar Lake, Panther Lake — **no Arrow Lake** (`7d41 7d51 7d67 7dd1`), even
though it's Meteor Lake graphics. (The interim test build retargeted one compiled ID compare.)

Step 1 (done, works on the MSI's Arrow Lake: detected as graphics IP 12.70): both libraries rebuilt from AOSP `external/minigbm`
(android17-release, same source as Google's; Google's own build is slightly newer in the core but
its C++ layout matches) by `gfx/build-minigbm.sh` with the NDK. Patch
`gfx/minigbm-patches/xe-unknown-gpus.patch`: a GPU missing from the tables is no longer rejected;
its generation comes from the graphics IP version the xe driver reports (Meteor Lake and newer;
older Xe GPUs report none and are Gen12). Google's allocator service, mapper and gralloc0 module
stay: our libraries are linked against the image's libc++ (`std::__1`) and the build checks that
every symbol the image's binaries import from Google's versions exists in ours. Built for the
plain x86-64 Android baseline: no extra CPU requirements (relevant for future old-CPU support).

Next steps (each needs hardware to test):
- AMD: compile minigbm's `amdgpu` backend (`DRV_AMDGPU`; static libdrm_amdgpu is already in the
  Mesa sysroot; tiled allocations go through Mesa's radeonsi DRI driver, which needs Mesa with LLVM).
- No GPU driver / unknown GPU: a fallback backend (vgem, or dumb buffers on simpledrm) tried
  only after every real GPU, and never by opening `card0` before hwcomposer (that would take DRM
  master away from it).
- If Google's allocator service or mapper ever become the limit (new AIDL versions, metadata),
  build them too: needs AIDL (already used by the build) + HIDL headers (gralloc4 types).
- nouveau backend: done (see NVIDIA below).

### NVIDIA (`gpu-nouveau`)

NVIDIA's own driver exists only for glibc Linux, so NVIDIA GPUs use the open stack Linux distros
use: nouveau (kernel), NVK (Vulkan), Zink (GL on Vulkan) or nouveau GL (Mesa).

- **Kernel module.** `DRM_NOUVEAU=m` in the generic profile; the feature puts `nouveau.ko` in
  vendor_dlkm, where ueventd loads it by device alias like the image's xe (`modules.alias`: only
  when an NVIDIA GPU is present; it loads before init continues, so before the composer). It links against
  Google's own drm helper modules, so the feature compares the CRC of every symbol it takes from
  them (107, all equal) and refuses to build on a mismatch. Google's `drm_ttm_helper` lacks one
  function (the fbdev console; GKI has no fbdev), so our build replaces it - allowed only because
  it exports everything Google's does with identical CRCs, so xe keeps loading.
- **Only where nothing else drives the display** (`kmod/patches/nouveau-hybrid-guard.patch`):
  nouveau doesn't bind when another display controller exists. Hybrid laptops keep today's Intel
  stack, and simpledrm isn't removed under it. `nouveau.hybrid=1` overrides. Desktops with the
  monitor on the NVIDIA card and the iGPU enabled: disable the iGPU in the BIOS.
- **Firmware** via `firmware-extra` (nouveau declares 519 names): GSP-RM 570.144 only
  (`skip.txt` drops the 535 fallback); linux-firmware's WHENCE links become hardlinks (one 60 MB
  GSP image serves 18 chip names). +95 MB on vendor.
- **Display:** drm_hwcomposer needs atomic KMS: `nouveau.atomic=1` (feature `cmdline`). nouveau
  scans out of VRAM only. It has no DSC support, so modes that need it (e.g. 2560x1600@240 on
  the MSI panel) are filtered out, and `nouveau-dsc-off.patch` clears the DSC state laptop
  firmware leaves behind for them. GB20x display fixes from mainline: `nouveau-up-*.patch`.
- **Buffers:** minigbm's dumb-buffer nouveau backend can't work (dumb buffers aren't allowed on
  render nodes), so `gfx/minigbm-patches/nouveau-native.patch` allocates with `NOUVEAU_GEM_NEW`:
  linear, pitch aligned to 256, VRAM (may spill to system memory) for anything the GPU or display
  touches, system memory for CPU-only buffers.
- **Rendering** (`gfx-nouveau.rc`): `ro.hardware.egl=mesa` - Mesa's loader picks Zink on NVK for
  Kepler and newer (`gfx/mesa-patches/nouveau-zink-from-kepler.patch`; upstream only from Turing,
  the only option from Blackwell on) and nouveau GL for Fermi and older (no NVK there): nouveau GL
  faulted across apps on the G20AJ's Maxwell, Zink on NVK ran clean (docs/02). Override:
  `debug.mesa.nouveau.use.zink=true/false`;
  `ro.hardware.vulkan=nouveau` (NVK) for apps. NVK has no AHardwareBuffer support upstream;
  `gfx/mesa-patches/nvk-android-hardware-buffer.patch` adds it (Chrome's ANGLE-on-Vulkan needs
  it). SurfaceFlinger and HWUI run Skia on Vulkan (NVK) via `nouveau-ui-vk.rc`; HWUI needs 2
  graphics queues (`gfx/mesa-patches/nvk-two-graphics-queues.patch`). `androidboot.churro.nouveau_ui=gl`
  goes back to Skia on GL (needed on Fermi and older: no Vulkan). Mesa is built with NVK
  (`gfx/build-mesa.sh`): its Rust parts use the kernel's Android Rust toolchain (Android std,
  panic=abort) and bindgen, plus cbindgen and the small libelf Mesa's own Android CI uses.
- **SELinux:** Mesa finds GPUs through libdrm, which reads the GPU's PCI ID files in sysfs from
  every app. Google labels them readable (`sysfs_gpu`) only at the iGPU's slot 00:02.0; the
  feature adds wildcard genfscon rules for function 0 of any device behind a PCIe bridge.
- **Coverage:** display on anything nouveau drives with atomic modesetting (GeForce 8 and newer).
  3D: Turing+ at full speed (GSP); Kepler..Volta work but nouveau can't reclock them (boot clocks,
  slow); Maxwell 2+ need signed firmware (included).
- **Not covered:** the NVIDIA GPU of hybrid machines stays unused (no PRIME render offload). No
  software fallback on nouveau: softpipe can't import buffers, llvmpipe would need LLVM.
