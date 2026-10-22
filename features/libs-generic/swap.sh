# Sourced by patch-system.sh / patch-vendor.sh. A file is swapped for the emulator's build only if
# that build exports everything the image's does (name + version) and has no instruction a
# Haswell lacks; otherwise the image's file stays and the log says why.
isa_bad() {  # instructions missing on Haswell: GFNI, AVX-VNNI/IFMA, SHA, VAES, VPCLMULQDQ, ADX, AVX-512
  # grep -c, not -q: with pipefail an early grep exit makes objdump's SIGPIPE the pipeline status
  [ "$(objdump -d --no-show-raw-insn "$1" 2>/dev/null |
    grep -cE 'gf2p8|vpdpw|vpdpb|vpmadd52|sha1msg|sha1rnds|sha1nexte|sha256|[[:space:]]vaes|vpclmul|[[:space:]]adc[x]|[[:space:]]ado[x]|zmm|%k[0-7]')" -gt 0 ]
}
exports() { nm -D --defined-only --with-symbol-versions "$1" 2>/dev/null | awk '{print $NF}' | sort -u; }
# swap_ok <image file> <emulator file>: 0 if the emulator file may replace the image's
swap_ok() {
  [ -f "$1" ] && [ -f "$2" ] || { why="missing"; return 1; }
  [ -z "$(comm -23 <(exports "$1") <(exports "$2"))" ] || { why="exports differ"; return 1; }
  ! isa_bad "$2" || { why="emulator copy uses newer instructions"; return 1; }
}
# swap_group <label> <image dir> <emulator dir> <relative paths...>: all or none (libc + linker
# from different builds must never meet). Written in place: SELinux labels and modes stay.
swap_group() {
  local n=$1 I=$2 E=$3 f; shift 3
  for f in "$@"; do swap_ok "$I/$f" "$E/$f" || { echo "   $n: kept the image's ($f: $why)"; return 0; }; done
  for f in "$@"; do cat "$E/$f" > "$I/$f"; done
  echo "   $n: emulator build (generic x86-64, no Panther Lake instructions)"
}
