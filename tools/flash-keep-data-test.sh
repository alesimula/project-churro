#!/usr/bin/env bash
# Self-check for flash-keep-data.sh (root: loop devices): a synthetic 64 MiB "stick" is updated
# from a .img and a .img.gz; kept partitions must stay, the rest must change; a foreign disk is refused.
set -e
S="$(dirname "$(realpath "$0")")/flash-keep-data.sh"
W=$(mktemp -d); cd $W
truncate -s 64M new.img
printf 'label: gpt\nstart=2048, size=8192, name="EFI-SYSTEM"\nstart=10240, size=8192, name="CHURRO-LOG"\nstart=18432, size=20480, name="super"\nstart=38912, size=8192, name="metadata"\nstart=47104, size=8192, name="misc"\nstart=55296, size=73728, name="userdata"\n' | sfdisk -q new.img
fill() { # fill <file> <tag>: every partition gets "<tag>-<name>" repeated
  sfdisk -d $1 | sed -n 's/.*start= *\([0-9]*\), size= *\([0-9]*\),.*name="\([^"]*\)".*/\1 \2 \3/p' | while read s n name; do
    yes "$2-$name" | head -c $((n*512)) | dd of=$1 bs=512 seek=$s conv=notrunc status=none; done; }
cp new.img stick.img; fill stick.img OLD; fill new.img NEW
gzip -k -1 new.img
L=$(losetup -f --show stick.img)
for img in new.img new.img.gz; do
  fill $L OLD
  bash "$S" $img $L --yes > out.txt 2>&1 || { cat out.txt; exit 1; }
  for p in EFI-SYSTEM:NEW CHURRO-LOG:OLD super:NEW metadata:OLD misc:NEW userdata:OLD; do
    n=${p%%:*} want=${p##*:}; s=$(sfdisk -d $L | sed -n "s/.*start= *\([0-9]*\),.*name=\"$n\".*/\1/p")
    got=$(dd if=$L bs=512 skip=$s count=1 status=none | head -c 3)
    [ "$got" = "$want" ] || { echo "FAIL $img $n: $got"; losetup -d $L; exit 1; }
  done; echo "ok $img"
done
truncate -s 32M other.img; printf 'label: gpt\nstart=2048, size=8192, name="x"\n' | sfdisk -q other.img
L2=$(losetup -f --show other.img); echo n | bash "$S" new.img $L 2>&1 | tail -1   # a "no" writes nothing
bash "$S" new.img $L2 2>&1 | tail -1; losetup -d $L2
losetup -d $L; rm -rf $W
