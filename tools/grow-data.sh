#!/usr/bin/env bash
# Grow Android's data (userdata, the last partition) of a Churro stick or disk to the end of the
# disk. Images have a fixed userdata (churro.sh --data-size, default 12 GiB): written to something
# bigger with Etcher/dd/Rufus, the rest stays unused (churro.sh install and the stick's own
# installer grow it themselves).
# On a disk Android was already started on it does nothing without --erase: Android formatted its
# filesystem once, at the old size, and it can't be grown safely from here. (Tried: unlocking it
# with the key from the metadata partition and running resize2fs. This ext4 has no resize_inode,
# so resize2fs moves data blocks; blocks of encrypted files are stored without the metadata
# encryption and came back corrupted - a real stick lost its keystore database, 2026-11-11.)
# --erase clears userdata, its keys (metadata) and the security state, like a new install:
# Android sets itself up again with all the space.
# Usage: sudo tools/grow-data.sh /dev/sdX [--yes] [--erase]   (DRY=1: plan only)
# From Windows: tools\grow-data.bat. Self-check: tools/grow-data-test.sh
set -euo pipefail
DEV=${1:?usage: grow-data.sh /dev/sdX [--yes] [--erase]}; shift; yes="" erase=""
for a in "$@"; do case $a in --yes) yes=1 ;; --erase) erase=1 ;; *) echo "grow-data: unknown option $a" >&2; exit 1 ;; esac; done
die() { echo "grow-data: $*" >&2; exit 1; }
[ -b "$DEV" ] || die "$DEV is not a block device"
grep -q "^$DEV" /proc/mounts && die "$DEV has mounted partitions"
# "<n> <start> <end> <name>" per partition (sectors; sgdisk cuts long names: match by prefix)
parts() { sgdisk -p "$DEV" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1, $2, $3, $NF}'; }
gib() { awk "BEGIN { printf \"%.1f GiB\", $1 / 2097152 }"; }
read -r un us ue _ < <(parts | awk '$4 == "userdata"') || true
[ -n "${un:-}" ] || die "no userdata partition on $DEV (not a Churro disk?)"
[ -z "$(parts | awk -v s="$us" '$2 > s')" ] || die "userdata isn't the last partition of $DEV (not written by Churro?)"
total=$(blockdev --getsz "$DEV"); last=$((total - 34))   # the backup GPT takes the last 33 sectors
room=""; [ $((last - ue)) -le 32768 ] || room=1          # under 16 MiB: not worth a new table
used=""; dd if="$DEV" bs=512 skip="$us" count=2048 status=none | cmp -s - <(head -c 1048576 /dev/zero) || used=1

lsblk -dno MODEL,SIZE "$DEV" | sed "s|^|$DEV: |"
if [ -n "$room" ]; then echo "userdata: $(gib $((ue - us + 1))) -> $(gib $((last - us + 1)))"
else echo "userdata: $(gib $((ue - us + 1))), already up to the end of the disk"; fi
if [ -n "$erase" ]; then echo "erase: Android's data, its keys and the security state will be ERASED (userdata, metadata, desktop_security_*, frp_persist)"
elif [ -z "$used" ]; then echo "Android hasn't used it yet: it formats it at that size on its first start"
else echo "Android was already started on this disk: its data can't be grown from here, only --erase gives it the space (erases Android's data)"; echo "nothing to do"; exit 0; fi
[ -n "$room$erase" ] || { echo "nothing to do"; exit 0; }
[ "${DRY:-0}" = 1 ] && exit 0
if [ -z "$yes" ]; then
  read -r -p "Go on with $DEV? [y/N] " a; [ "$a" = y ] || die "cancelled, nothing written"
fi

if [ -n "$room" ]; then   # same partition (type, GUID, flags, name), new end; backup GPT moved to the disk's end
  i=$(sgdisk -i "$un" "$DEV")
  t=$(sed -n 's/^Partition GUID code: \([0-9A-F-]*\).*/\1/p' <<< "$i"); u=$(sed -n 's/^Partition unique GUID: //p' <<< "$i")
  at=$(sed -n 's/^Attribute flags: //p' <<< "$i")
  sgdisk -e "$DEV" >/dev/null
  sgdisk -d "$un" -n "$un:$us:0" -t "$un:$t" -u "$un:$u" -A "$un:=:$at" -c "$un:userdata" "$DEV" >/dev/null
  partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
  echo ">> userdata grown to $(gib $(( $(parts | awk '$4 == "userdata" {print $3}') - us + 1 )))"
fi
if [ -n "$erase" ]; then   # blank = "format me" for Android (formattable in its fstab), as on a new install
  parts | while read -r n s e name; do
    case $name in userdata) c=$((16 << 20)) ;; metadata|desktop_security_*|frp_persist) c=$(((e - s + 1) * 512)) ;; *) continue ;; esac
    dd if=/dev/zero of="$DEV" bs=1M iflag=count_bytes oflag=seek_bytes count=$c seek=$((s * 512)) conv=notrunc status=none
    echo ">> $name cleared"
  done
fi
sync
echo "done"
