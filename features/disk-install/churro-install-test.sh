#!/usr/bin/env bash
# Self-check for churro-install on loop devices (root, Linux; SH=mksh runs it under Android's
# shell): a new install onto a smaller and dirty disk, then an update that keeps the data, plus
# the refusals (cancel, too small, no install, downgrade, disk in use).
set -euo pipefail
S="$(dirname "$(realpath "$0")")/churro-install"; W=$(mktemp -d); cd "$W"
L=(); trap 'umount m 2>/dev/null; for l in "${L[@]}"; do losetup -d $l; done; cd /; rm -rf "$W"' EXIT
mkdir bin m; printf '#!/bin/sh\necho POWEROFF\nexit 1\n' > bin/reboot; chmod +x bin/reboot
loop() { R=$(losetup -fP --show "$1"); L+=("$R"); R=${R#/dev/}; }   # -> $R
fill() { { yes "$1" || true; } | dd of="$2" bs=1M iflag=fullblock count="$3" status=none; }   # <text> <device> <MiB>
esp() { mkfs.vfat "$1" >/dev/null; mount "$1" m; mkdir -p m/churro m/EFI/BOOT
  printf 'set boot_source=external\nset extra_args=""\n' > m/churro/env.cfg; printf '%s CHURRO-ESPID:%036d end' "$2" 0 > m/EFI/BOOT/BOOTX64.EFI
  echo $(( ${#2} + 14 )) > m/churro/espid.off
  printf 'BUILD_ID=B%s\nINCREMENTAL=%s\nCHURRO_BUILT=2026-11-10\n' "$3" "$3" > m/churro/build.txt; umount m; }
# run <mode> <candidate disks> <typed lines...>: output in out.txt, exit status returned
run() { local mode=$1 disks=$2; shift 2
  printf '%s\n' "$@" | PATH=$W/bin:$PATH CHURRO_INSTALL_SRC=$src CHURRO_INSTALL_DISKS="$disks" CHURRO_INSTALL_MINDATA=64 \
    ${SH:-sh} "$S" $mode > out.txt 2>&1; }
ok() { echo "ok $1"; }; fail() { echo "FAIL $1"; cat out.txt; exit 1; }
sum() { sha256sum "$1" | cut -c1-16; }

# the "stick": Churro's numbering, userdata (partition 1) last and grown
truncate -s 300M src.img
sgdisk -n 12:2048:+8M -t 12:EF00 -c 12:EFI-SYSTEM -n 2:0:+8M -t 2:0700 -c 2:CHURRO-LOG -n 3:0:+17M -c 3:super \
  -n 6:0:+1 -c 6:KERN-C -n 15:0:+1M -c 15:vbmeta_a -A 15:set:48 -A 15:set:56 -n 17:0:+4M -c 17:metadata \
  -n 24:0:+1M -c 24:misc -n 29:0:+1M -c 29:desktop_security_persist -n 31:0:+1M -c 31:frp_persist \
  -n 1:0:0 -c 1:userdata src.img >/dev/null
loop src.img; src=$R; s=/dev/$src
esp ${s}p12 GRUB1 100; mkfs.vfat ${s}p2 >/dev/null
fill SUPER1 ${s}p3 17; fill STICKSTATE ${s}p17 4; fill STICKMISC ${s}p24 1; fill STICKSEC ${s}p29 1; fill STICKDATA ${s}p1 20
before=$(sum src.img)

# refusals first: nothing may change
{ tr '\0' '\377' < /dev/zero || true; } | head -c 200M > dst.img; loop dst.img; dst=$R; d=/dev/$dst; dsum=$(sum dst.img)
run new $dst "" && grep -q "Cancelled" out.txt && [ "$(sum dst.img)" = "$dsum" ] && ok "cancel at the disk list" || fail cancel
run new $dst 1 no && grep -q "Cancelled" out.txt && [ "$(sum dst.img)" = "$dsum" ] && ok "anything but YES cancels" || fail no
run update $dst "" && grep -q "no Churro install" out.txt && ok "update: a disk without Churro isn't offered" || fail noinstall
truncate -s 80M tiny.img; loop tiny.img; tiny=$R
run new $tiny "" && grep -q "too small" out.txt && ok "new: too small a disk isn't offered" || fail small
run new "$src" 1 && grep -q "^ none" out.txt && ! grep -q ERASES out.txt && ok "the running disk is never listed" || fail self

# new install onto a smaller disk full of old data
run new $dst 1 YES "" && grep -q "^Done" out.txt && grep -q POWEROFF out.txt || fail "new install"
[ "$(sum src.img)" = "$before" ] || fail "the stick was modified"
[ "$(sgdisk -p $d | awk '$NF == "userdata" {print $2}')" = "$(sgdisk -p $s | awk '$NF == "userdata" {print $2}')" ] || fail "userdata start"
sgdisk -v $d | grep -q "No problems found" || fail "target GPT has problems"
[ "$(sgdisk -p $d | grep identifier)" != "$(sgdisk -p $s | grep identifier)" ] || fail "same disk GUID"
[ "$(sgdisk -i 12 $d | grep unique)" != "$(sgdisk -i 12 $s | grep unique)" ] || fail "same ESP GUID"
sgdisk -i 15 $d | grep -q "Attribute flags: 0101000000000000" || fail "vbmeta_a slot flags lost"
[ $(( $(blockdev --getsz ${d}p1) )) -gt 200000 ] || fail "userdata not grown to the disk"
cmp -s ${s}p3 ${d}p3 && cmp -s ${s}p6 ${d}p6 || fail "partitions not copied"   # p2 (CHURRO-LOG): own GRUB
for p in 17 24 29 31; do cmp -s -n $(( $(blockdev --getsize64 ${d}p$p) )) ${d}p$p /dev/zero || fail "p$p not cleared"; done
cmp -s -n $((16 << 20)) ${d}p1 /dev/zero || fail "userdata not cleared"
mount -o ro ${d}p12 m; grep -q "boot_source=internal" m/churro/env.cfg && grep -q GRUB1 m/EFI/BOOT/BOOTX64.EFI || fail "ESP"; umount m
id() { blkid -p -o value -s PART_ENTRY_UUID ${d}p12; }   # GRUB knows its disk (lib/esp.sh esp_set_id)
mount -o ro ${d}p12 m; grep -q "GRUB1 CHURRO-ESPID:$(id) end" m/EFI/BOOT/BOOTX64.EFI || fail "ESP ID in GRUB"; umount m
mount -o ro ${d}p2 m; grep -q "CHURRO-ESPID:$(id) end" m/EFI/BOOT/BOOTX64.EFI || fail "ESP ID in CHURRO-LOG's GRUB"; umount m
ok "new install: table, new GUIDs, copy, cleared state, boot_source=internal"

# update: a newer stick; Android's state and the logs on the target stay
fill SUPER2 ${s}p3 17; esp ${s}p12 GRUB2 200
fill MYDATA ${d}p1 20; fill MYKEYS ${d}p17 4; fill MYSEC ${d}p29 1; fill OLDMISC ${d}p24 1
mount ${d}p2 m; echo mylog > m/boot.log; umount m
for p in 1 17 29; do sum ${d}p$p; done > keep.txt; tguid=$(sgdisk -p $d | grep identifier)
run update "$dst $tiny" 1 yes "" && grep -q "^Done" out.txt || fail update
grep -q "from: Googlebook OS B100" out.txt && grep -q "to: Googlebook OS B200" out.txt || fail "old/new version not shown"
cmp -s ${s}p3 ${d}p3 || fail "super not updated"
[ "$(for p in 1 17 29; do sum ${d}p$p; done)" = "$(cat keep.txt)" ] || fail "Android's state was touched"
cmp -s -n $((1 << 20)) ${d}p24 /dev/zero || fail "misc not cleared"
[ "$(sgdisk -p $d | grep identifier)" = "$tguid" ] || fail "GUIDs changed by an update"
mount ${d}p12 m; grep -q "boot_source=internal" m/churro/env.cfg && grep -q GRUB2 m/EFI/BOOT/BOOTX64.EFI || fail "ESP after update"; umount m
mount ${d}p2 m; grep -q mylog m/boot.log && grep -q "GRUB2 CHURRO-ESPID:$(id) end" m/EFI/BOOT/BOOTX64.EFI || fail "CHURRO-LOG: logs kept + new GRUB"; umount m
ok "update: system rewritten, data/keys/logs kept, versions shown"

esp ${s}p12 GRUB0 50; usum=$(sum ${d}p3)   # an older stick
run update $dst 1 && false || { grep -q "newer Googlebook OS" out.txt && [ "$(sum ${d}p3)" = "$usum" ] && ok "update: downgrade refused" || fail downgrade; }
mount ${d}p2 m
run update $dst "" && grep -q "in use" out.txt && ok "a mounted disk isn't offered" || fail inuse
umount m
echo "all passed (${SH:-sh})"
