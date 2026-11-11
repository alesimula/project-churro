#!/usr/bin/env bash
# Self-check for grow-data.sh on a loop device (root): an image "written to a bigger stick".
set -euo pipefail
S="$(dirname "$(realpath "$0")")/grow-data.sh"; W=$(mktemp -d); cd "$W"; L=""
trap '[ -z "$L" ] || losetup -d $L; cd /; rm -rf "$W"' EXIT
fail() { echo "FAIL $1"; cat out.txt 2>/dev/null; exit 1; }
truncate -s 100M s.img
sgdisk -n 12:2048:+8M -t 12:EF00 -c 12:EFI-SYSTEM -n 17:0:+4M -c 17:metadata -n 29:0:+1M -c 29:desktop_security_persist \
  -n 31:0:+1M -c 31:frp_persist -n 3:0:+16M -c 3:super -n 1:0:0 -c 1:userdata -A 1:set:60 s.img >/dev/null
truncate -s 300M s.img; L=$(losetup -fP --show s.img)   # the image on a bigger disk: backup GPT in the middle
fill() { { yes "$1" || true; } | dd of=${L}p$2 bs=1M iflag=fullblock count=$3 status=none; }
fill SUPER 3 16; fill KEYS 17 4; fill SEC 29 1; sum=$(sha256sum ${L}p3 | cut -c1-16); guid=$(sgdisk -i 1 $L | grep unique)

DRY=1 bash "$S" $L > out.txt; grep -q "hasn't used it yet" out.txt && grep -q " -> " out.txt || fail "plan"
bash "$S" $L --yes > out.txt || fail grow
[ "$(blockdev --getsz ${L}p1)" -gt 500000 ] && sgdisk -v $L | grep -q "No problems found" || fail "not grown / bad GPT"
[ "$(sgdisk -i 1 $L | grep unique)" = "$guid" ] && sgdisk -i 1 $L | grep -q "flags: 1000000000000000" || fail "GUID/flags lost"
[ "$(sha256sum ${L}p3 | cut -c1-16)" = "$sum" ] || fail "other partitions touched"
echo "ok grown to the end, same partition, the rest untouched"
bash "$S" $L --yes > out.txt && grep -q "nothing to do" out.txt || fail "second run"; echo "ok nothing to do the second time"

sgdisk -d 1 -n 1:0:+20M -c 1:userdata $L >/dev/null; partprobe $L; fill DATA 1 20; sum1=$(sha256sum ${L}p1 | cut -c1-16)   # Android has formatted it
bash "$S" $L --yes > out.txt && grep -q "already started" out.txt && grep -q "nothing to do" out.txt && [ "$(sha256sum ${L}p1 | cut -c1-16)" = "$sum1" ] || fail "used disk"
echo "ok a started disk: data left alone"
bash "$S" $L --yes --erase > out.txt || fail erase
for p in 17 29 31; do cmp -s -n $(blockdev --getsize64 ${L}p$p) ${L}p$p /dev/zero || fail "p$p not cleared"; done
cmp -s -n $((16 << 20)) ${L}p1 /dev/zero && [ "$(sha256sum ${L}p3 | cut -c1-16)" = "$sum" ] && [ "$(blockdev --getsz ${L}p1)" -gt 500000 ] || fail "erase"
echo "ok --erase clears Android's state only"
echo "all passed"
