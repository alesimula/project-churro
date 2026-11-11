#!/usr/bin/env bash
# Self-check for logger.c's choice of CHURRO-LOG (root, Linux): two "Churro disks" on loop devices,
# each with an ESP and a CHURRO-LOG; the logger must take the one on the disk whose ESP ID is on
# the kernel cmdline (androidboot.boot_part_uuid), any one without it.
set -euo pipefail
F="$(dirname "$(realpath "$0")")"; W=$(mktemp -d); cd "$W"; L=()
trap 'for l in "${L[@]}"; do losetup -d $l; done; cd /; rm -rf "$W"' EXIT
cat > t.c <<'C'
#define main logger_main
#include "logger.c"
#undef main
int main(int c, char **v) { unsigned ma = 0, mi = 0; (void)c; (void)v;
  if (!pick(&ma, &mi, 0, 100) && !pick(&ma, &mi, 100, 100)) return 1;
  printf("%u:%u\n", ma, mi); return 0; }
C
cc -O1 -w -I"$F" -o t t.c
for n in a b; do
  truncate -s 40M $n.img
  sgdisk -n 12:2048:+4M -t 12:EF00 -c 12:EFI-SYSTEM -n 2:0:+4M -t 2:0700 -c 2:CHURRO-LOG -n 1:0:0 -c 1:userdata $n.img >/dev/null
  l=$(losetup -fP --show $n.img); L+=($l); eval $n=$l
done
sleep 1; ln -s /sys sys; mkdir proc
want() { cat /sys/class/block/${1##*/}p2/dev; }
uuid() { sgdisk -i 12 $1 | sed -n 's/^Partition unique GUID: //p'; }
check() { echo "x androidboot.boot_part_uuid=$2 y" > proc/cmdline; got=$(./t)
  [ "$got" = "$3" ] && echo "ok $1" || { echo "FAIL $1: got $got, want $3"; exit 1; }; }
check "booted from disk b" "$(uuid $b | tr A-Z a-z)" "$(want $b)"
check "booted from disk a (upper-case ID)" "$(uuid $a)" "$(want $a)"
echo "nothing" > proc/cmdline; any=$(./t) && [ -n "$any" ] && echo "ok no ID on the cmdline: some CHURRO-LOG ($any)" || { echo "FAIL no ID"; exit 1; }
check "unknown ID: the same fallback after the wait" "00000000-0000-0000-0000-000000000000" "$any"
echo "all passed"
