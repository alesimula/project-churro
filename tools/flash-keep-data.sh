#!/usr/bin/env bash
# Update a Churro USB stick (or installed disk) in place from a newer build, keeping Android's
# data: writes every partition except userdata, metadata (userdata's encryption keys), the
# security-state partitions and the log partition. Only for builds of the same Android version
# (same recovery image, same --data-size): the layout must match exactly, or it refuses.
# Usage: sudo tools/flash-keep-data.sh <churro.img | churro.img.gz> /dev/sdX [--yes]   (DRY=1: plan only)
# From WSL: attach the stick with usbipd-win first (README, "Updating a stick without losing data").
# Self-check: tools/flash-keep-data-test.sh
set -euo pipefail
IMG=$1 DEV=$2
KEEP='(userdata|metadata|desktop_security_.*|frp_persist|CHURRO-LOG)'
die() { echo "flash-keep-data: $*" >&2; exit 1; }
[ -f "$IMG" ] || die "no image $IMG"
[ -b "$DEV" ] || die "$DEV is not a block device"
case $IMG in *.gz) rd() { gzip -dc "$IMG"; } ;; *) rd() { cat "$IMG"; } ;; esac

# "<start> <size> <name>" per partition (sectors), from a GPT on a file or device
parts() { sfdisk -d "$1" 2>/dev/null | sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name="\([^"]*\)".*/\1 \2 \3/p' | sort -n; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rd | head -c 1M > "$T/head" || true   # the GPT is in the first 17 KiB
# sfdisk wants the whole disk: grow the copy (sparse) to the size the GPT header records
# (backup header LBA at byte 544)
alt=$(od -An -t u8 -j 544 -N 8 "$T/head" | tr -d ' ')
[ -n "$alt" ] && truncate -s $(( (alt + 1) * 512 )) "$T/head"
parts "$T/head" > "$T/img"
parts "$DEV" > "$T/dev"
[ -s "$T/img" ] || die "no GPT in $IMG"
# same partitions at the same places (userdata may be bigger on the stick: grown to the disk)
diff <(grep -v ' userdata$' "$T/img") <(grep -v ' userdata$' "$T/dev") >/dev/null ||
  die "$DEV doesn't have this image's partition layout (not a Churro stick, or another build/data size): use a full flash"
[ "$(awk '$3 == "userdata" {print $1}' "$T/img")" = "$(awk '$3 == "userdata" {print $1}' "$T/dev")" ] ||
  die "userdata starts elsewhere on $DEV: use a full flash"
grep -q "^/dev/${DEV##*/}" /proc/mounts && die "$DEV has mounted partitions"

lsblk -dno MODEL,SIZE "$DEV" | sed "s|^|$DEV: |"
echo "keeping: $(grep -E " $KEEP$" "$T/img" | awk '{print $3}' | tr '\n' ' ')"
echo "writing: $(grep -vE " $KEEP$" "$T/img" | awk '{print $3}' | tr '\n' ' ')"
[ "${DRY:-0}" = 1 ] && exit 0
if [ "${3:-}" != --yes ]; then   # --yes: already confirmed (flash-keep-data.bat asks first)
  read -r -p "Overwrite those partitions on $DEV? [y/N] " a
  [ "$a" = y ] || die "cancelled, nothing written"
fi

# one sequential pass over the image (works for .gz too): skip the kept ranges, write the rest
exec 3< <(rd)
pos=0
grep -vE " $KEEP$" "$T/img" | while read -r s n name; do
  [ "$s" -ge "$pos" ] || die "overlapping partitions at $name"
  dd bs=4M iflag=fullblock,count_bytes count=$(( (s - pos) * 512 )) of=/dev/null status=none <&3
  echo ">> $name ($((n * 512 >> 20)) MiB)"
  dd bs=4M iflag=fullblock,count_bytes count=$((n * 512)) of="$DEV" oflag=seek_bytes seek=$((s * 512)) \
     conv=notrunc status=progress <&3
  pos=$((s + n))
done
sync
# CHURRO-LOG keeps its logs but gets the new GRUB from the ESP just written (lib/esp.sh: firmware
# boot menus list it before the ESP). Best effort: the update itself is done.
esp=$(awk '$3 == "EFI-SYSTEM" {print $1, $2}' "$T/img"); lg=$(awk '$3 == "CHURRO-LOG" {print $1, $2}' "$T/dev")
if [ -n "$esp" ] && [ -n "$lg" ]; then
  E=$(mktemp -d) L=$(mktemp -d)
  read -r es en <<< "$esp"; read -r ls_ lnn <<< "$lg"
  note="note: CHURRO-LOG's boot loader not updated (its firmware boot entry may do nothing)"
  if mount -o ro,offset=$((es * 512)),sizelimit=$((en * 512)) "$DEV" "$E"; then
    if mount -o offset=$((ls_ * 512)),sizelimit=$((lnn * 512)) "$DEV" "$L"; then
      mkdir -p "$L/EFI/BOOT" && cp "$E/EFI/BOOT/BOOTX64.EFI" "$L/EFI/BOOT/" && echo ">> CHURRO-LOG: boot loader updated" ||
        echo "$note"
      umount "$L"
    else echo "$note"; fi
    umount "$E"
  else echo "$note"; fi
  rmdir "$E" "$L"
fi
echo "done: boot it; Android keeps its data and apps"
