#!/usr/bin/env bash
# Core libraries the image builds for Panther Lake (GFNI, AVX-VNNI, VPCLMULQDQ... used without
# asking the CPU), replaced by Google's generic x86-64 builds of the same files from the emulator
# image of the same Android release (lib/emu-image.sh). Biggest emulator trap sources on older
# CPUs after BoringSSL: libz (Adler-32/CRC: every download, APK, PNG) and bionic (libc string
# routines, the dynamic linker), in every process.
#  - libz: /system/lib64 (vendor: patch-vendor.sh).
#  - bionic, early copies: /system/lib64/bootstrap + /system/bin/bootstrap/linker64 (init and the
#    processes started before APEXes are mounted).
#  - bionic, everyone else: the com.android.runtime APEX, swapped as a whole file (same name and
#    version, everything inside from one build); apexd trusts APEX files on /system. Not a
#    Play-updatable module. The signed APEXes of updatable modules are left alone.
set -euo pipefail
. "$(dirname "$0")/../../versions.env"
. "$(dirname "$0")/../../lib/emu-image.sh"
. "$(dirname "$0")/swap.sh"
S=$1/system E=$(emu_part system)/system
emu_same_api "$S/build.prop" "$E/build.prop" || { echo "   libs-generic: kept the image's libz + bionic"; exit 0; }

swap_group "system/lib64/libz.so" "$S" "$E" lib64/libz.so
swap_group "bionic bootstrap (libc, libm, libdl, linker)" "$S" "$E" \
  lib64/bootstrap/libc.so lib64/bootstrap/libm.so lib64/bootstrap/libdl.so \
  lib64/bootstrap/libdl_android.so bin/bootstrap/linker64

# runtime APEX: unpack both payloads, check like above, then replace the .apex file
A=apex/com.android.runtime.apex X=$(mktemp -d); trap 'rm -rf "$X"' EXIT
for s in img emu; do
  [ $s = img ] && f=$S/$A || f=$E/$A
  [ -f "$f" ] || { echo "   runtime APEX: kept the image's ($s copy missing)"; exit 0; }
  mkdir -p "$X/$s"; unzip -p "$f" apex_payload.img > "$X/$s.img"
  "${EROFS_BIN:?}/fsck.erofs" --extract="$X/$s/x" "$X/$s.img" >/dev/null 2>&1 ||
    { mkdir -p "$X/$s/x"; debugfs -R "rdump / $X/$s/x" "$X/$s.img" >/dev/null 2>&1; }
done
I=$X/img/x J=$X/emu/x
if ! cmp -s "$I/apex_manifest.pb" "$J/apex_manifest.pb"; then
  echo "   runtime APEX: kept the image's (emulator APEX has another name/version)"
elif [ "$(cd "$I" && find . -type f | sort)" != "$(cd "$J" && find . -type f | sort)" ]; then
  echo "   runtime APEX: kept the image's (different file list)"
else
  ok=1
  for f in lib64/bionic/libc.so lib64/bionic/libm.so lib64/bionic/libdl.so lib64/bionic/libdl_android.so bin/linker64; do
    swap_ok "$I/$f" "$J/$f" || { echo "   runtime APEX: kept the image's ($f: $why)"; ok=0; break; }
  done
  if [ $ok = 1 ]; then
    for f in $(cd "$J" && find . -type f); do
      [ "$(head -c4 "$J/$f" | tail -c3)" = ELF ] || continue
      ! isa_bad "$J/$f" || { echo "   runtime APEX: kept the image's ($f: newer instructions)"; ok=0; break; }
    done
  fi
  [ $ok = 0 ] || { cat "$E/$A" > "$S/$A"; echo "   runtime APEX (bionic: libc, libm, linker64, ...): emulator build"; }
fi
