#!/usr/bin/env bash
# Build + run vextest for the Churro VEX #UD emulator (kmod/patches/vex-emulate.patch).
#   tools/vextest/run.sh build          compile static test binary (out in /tmp/vextest)
#   tools/vextest/run.sh native         run on this machine native-only (ground truth check)
#   tools/vextest/run.sh qemu <bzImage> [emulator-mode]
#       boot a bare initramfs on <bzImage> under TCG with a gap CPU; modes:
#       emu  = "-cpu max,-avx-vnni,-avx-ifma,-vaes,-vpclmulqdq,-sha-ni,-adx churro.vexemu=1": emulated
#              cases -> PASS (VAES/VPCLMULQDQ via the native AES-NI/PCLMULQDQ fast path)
#       emu-c = emu without AES-NI/PCLMULQDQ: the same cases through the C fallback
#       off  = same CPU + "churro.vexemu=0":                      init must die with SIGILL
#       max  = "-cpu max" (TCG's native mix; VNNI emulated or native depending on QEMU)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=/tmp/vextest; mkdir -p "$T"
B=$T/vextest

do_build() {
  gcc -static -nostdlib -ffreestanding -fno-stack-protector -O1 \
      -o "$B" "$HERE/vextest.c" "$HERE/vexops.S"
  echo "built $B"
  # verify the hand-encoded bytes disassemble to the intended instructions
  objdump -d "$B" >"$T/vextest.dis"
  for want in vpdpbusd vpdpbusds vpdpwssd vpdpwssds vpmadd52luq vpmadd52huq \
              vgf2p8affineqb vgf2p8affineinvqb vgf2p8mulb vpclmul \
              vpsadbw vpmaddubsw vpmaddwd \
              sha256rnds2 sha256msg1 sha256msg2 sha1nexte sha1msg1 sha1msg2 sha1rnds4 \
              vaesenc vaesenclast vaesdec vaesdeclast; do
    grep -q "$want" "$T/vextest.dis" && echo "  disasm ok: $want" || { echo "  DISASM MISSING: $want"; exit 1; }
  done
  grep -aE 'vpdp|vpmadd' "$T/vextest.dis" | sort -u | sed 's/^/  /' | head -24
}

case ${1:-} in
build) do_build ;;
native) [ -x "$B" ] || do_build; exec "$B" native ;;
qemu)
  [ -x "$B" ] || do_build
  BZ=$2; MODE=${3:-emu}
  case $MODE in
    emu) CPU='max,-avx-vnni,-avx-ifma,-vaes,-vpclmulqdq,-sha-ni,-adx'; EX='churro.vexemu=1' ;;
    emu-c) CPU='max,-avx-vnni,-avx-ifma,-vaes,-vpclmulqdq,-sha-ni,-adx,-aes,-pclmulqdq'; EX='churro.vexemu=1' ;;
    off) CPU='max,-avx-vnni,-avx-ifma,-vaes,-vpclmulqdq,-sha-ni,-adx'; EX='churro.vexemu=0' ;;
    max) CPU='max'; EX='churro.vexemu=1' ;;
    *) echo "unknown mode $MODE" >&2; exit 1 ;;
  esac
  rm -rf "$T/root"; mkdir -p "$T/root/dev"
  cp "$B" "$T/root/init"
  mknod -m666 "$T/root/dev/console" c 5 1 2>/dev/null || true
  mknod -m666 "$T/root/dev/ttyS0" c 4 64 2>/dev/null || true
  mknod -m666 "$T/root/dev/null" c 1 3 2>/dev/null || true
  # vextest logs via /dev/kmsg: GKI has no devtmpfs and its 8250 is a module (no /dev/ttyS0 tty)
  mknod -m666 "$T/root/dev/kmsg" c 1 11 2>/dev/null || true
  (cd "$T/root" && find . | cpio -o -H newc --quiet | gzip -1 > "$T/initrd.cpio.gz")
  LOG=$T/qemu-$MODE.log
  echo ">> booting $BZ (TCG $CPU, $EX) — log $LOG"
  timeout 600 qemu-system-x86_64 -accel tcg -machine q35 -cpu "$CPU" -smp 2 -m 1G \
    -kernel "$BZ" -initrd "$T/initrd.cpio.gz" \
    -append "earlycon=uart8250,io,0x3f8 console=ttyS0 loglevel=7 printk.devkmsg=on $EX panic=1" \
    -display none -no-reboot -serial file:"$LOG" </dev/null || true
  echo "---- VEXTEST lines ----"
  grep -a 'VEXTEST\|churro-vexemu\|trap invalid' "$LOG" | tail -30
  ;;
*) echo "usage: $0 build|native|qemu <bzImage> [emu|off|max]" >&2; exit 1 ;;
esac
