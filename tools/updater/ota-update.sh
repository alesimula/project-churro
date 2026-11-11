#!/usr/bin/env bash
# Apply the update Google offers a Googlebook recovery image, locally (no device).
# Usage: tools/updater/ota-update.sh <recovery.bin> [out_dir]         updated <partition>.img files
#        tools/updater/ota-update.sh <recovery.bin> --bin <new.bin>   updated copy of the whole image
#        tools/updater/ota-update.sh <recovery.bin> --in-place [--undoable]   update the image itself (no 19 GB copy)
#        tools/updater/ota-update.sh <recovery.bin> --revert          undo the last --in-place --undoable update
#   out_dir defaults to out/ota-update. --bin never overwrites: it refuses an existing file and
#   builds <new.bin>.part, renamed only once every partition checks out.
#   --in-place keeps nothing: a run that fails or is stopped leaves the image half updated (a mix of
#   two builds). A full package can then be applied again to finish (the command is printed); after
#   a delta only another copy of the image helps.
#   --in-place --undoable first saves the old content of every partition it replaces (~4 GB, and
#   that much more reading and writing) in <recovery.bin>.undo/. A run that fails or is stopped
#   puts the image back by itself; after a kill or power cut, --revert does. The folder stays after
#   a good run so --revert can go back to the old build, until the next --in-place removes it;
#   delete it to free the space. It belongs to that image file.
# Steps: buildinfo.sh (fingerprint + build timestamp) -> ota-check.sh (the package Google offers
# that build: a ~40 MB delta, or a ~3 GB full when it has no delta from it) -> download it (cached;
# the file name is its SHA-1, checked) and AOSP's prebuilt ota_extractor (ci.android.com
# otatools.zip, x86_64 Linux, cached) -> for each partition in the package: for a delta, cut its
# source out of the .bin (GPT *_a or super *_a, no root); apply with ota_extractor (update_engine's
# code, so VABC LZ4DIFF ops work), write it out and check it against the payload's target SHA-256
# (with --bin: read back from the new image). One partition at a time, so temporary space peaks at
# ~2x the largest partition (~4 GB) and no .img files are left behind with --bin.
# A delta works because the .bin is the stock build, where it applies cleanly; a full needs no source.
# With --bin, a partition bigger than its place in super is grown there or moved to super's free
# space (lib/lpinfo.py grow); one bigger than its GPT partition stops the run.
# Env: CHURRO_OTA_CACHE (default out/ota-cache), OTATOOLS_BUILD=<ci build id> to pin otatools,
#      FINGERPRINT + DATE_UTC to skip buildinfo.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
BIN="" OUT="" NEW="" INPLACE="" UNDOABLE="" REVERT="" DIRTY=""
while [ $# -gt 0 ]; do
  case $1 in
    --bin) shift; NEW=${1:?--bin needs a file name} ;;
    --in-place) INPLACE=1 ;; --undoable) UNDOABLE=1 ;; --revert) REVERT=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) if [ -z "$BIN" ]; then BIN=$1; elif [ -z "$OUT" ]; then OUT=$1; else echo "too many arguments" >&2; exit 1; fi ;;
  esac; shift
done
[ -f "$BIN" ] || { echo "usage: ota-update.sh <recovery.bin> [out_dir | --bin <new.bin> | --in-place [--undoable] | --revert]" >&2; exit 1; }
[ -z "$INPLACE$REVERT" ] || [ -z "$NEW$OUT" ] || { echo "--in-place / --revert take no output" >&2; exit 1; }
[ -z "$UNDOABLE" ] || [ -n "$INPLACE" ] || { echo "--undoable goes with --in-place" >&2; exit 1; }
UNDO=$BIN.undo   # plan: "<file> <byte offset in the image>" per saved range; done: the update finished
revert() {       # a range whose file is missing was never overwritten (it is saved, fsync'ed, before the write)
  local f o
  if [ -f "$UNDO/plan" ]; then while read -r f o; do
    [ ! -f "$UNDO/$f" ] || dd if="$UNDO/$f" of="$BIN" bs=4M oflag=seek_bytes seek="$o" conv=notrunc,fsync status=none
  done <"$UNDO/plan"; fi
  rm -rf "$UNDO"
}
if [ -n "$REVERT" ]; then
  [ -d "$UNDO" ] || { echo "nothing to revert: no $UNDO (only an --in-place --undoable update leaves one)" >&2; exit 1; }
  revert; echo "reverted: $BIN is $("$HERE/buildinfo.sh" "$BIN" | sed -n 's/^FINGERPRINT=//p') again" >&2; exit 0
fi
if [ -n "$INPLACE" ] && [ -e "$UNDO" ] && [ ! -e "$UNDO/done" ]; then
  echo "an in-place update of $BIN stopped half way: run ota-update.sh <recovery.bin> --revert first" >&2; exit 1
fi
OUT=${OUT:-$ROOT/out/ota-update}
CACHE=${CHURRO_OTA_CACHE:-$ROOT/out/ota-cache}
# shellcheck source-path=SCRIPTDIR source=../../lib/deps.sh
. "$ROOT/lib/deps.sh"; deps_ensure updater         # missing packages -> "sudo apt-get install ..."
for t in python3 curl unzip sgdisk dd sha256sum sha1sum; do command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }; done
if [ -n "$NEW" ]; then [ ! -e "$NEW" ] || { echo "$NEW exists, not overwriting" >&2; exit 1; }; mkdir -p "$(dirname "$NEW")"; fi
mkdir -p "$CACHE"

# 1-2. what does Google offer this build?
[ -n "${FINGERPRINT:-}" ] && [ -n "${DATE_UTC:-}" ] || eval "$("$HERE/buildinfo.sh" "$BIN")"
eval "$(OTA_TS=$DATE_UTC "$HERE/ota-check.sh" "$FINGERPRINT")"
[ -n "${OTA_PKG:-}" ] || { echo "no update offered for $FINGERPRINT" >&2; exit 1; }
echo "update ($OTA_TYPE, $((OTA_SIZE / 1000000)) MB): $FINGERPRINT -> $OTA_NFO" >&2

# 3a. the package (content-addressed: name == sha1); -C -: a stopped ~3 GB full download resumes
ZIP=$CACHE/${OTA_PKG##*/}; SHA=$(basename "$ZIP" .zip)
if [ ! -f "$ZIP" ] || [ "$(sha1sum "$ZIP" | cut -d' ' -f1)" != "$SHA" ]; then
  echo "downloading ${OTA_PKG##*/}" >&2; curl -fL -C - --retry 3 --progress-bar -o "$ZIP.part" "$OTA_PKG" && mv "$ZIP.part" "$ZIP"
  [ "$(sha1sum "$ZIP" | cut -d' ' -f1)" = "$SHA" ] || { echo "sha1 mismatch on $ZIP" >&2; exit 1; }
fi
POFF=$(python3 "$HERE/payload.py" offset "$ZIP")

# 3b. ota_extractor from AOSP CI otatools.zip
OT=$CACHE/otatools; X=$OT/bin/ota_extractor
if [ ! -x "$X" ]; then
  ST=$(curl -fsS https://ci.android.com/builds/branches/aosp-android-latest-release/status.json)
  TGT=$(python3 -c 'import sys,json;print([t["name"] for t in json.load(sys.stdin)["targets"] if "x86_64" in t["name"] and "phone" in t["name"]][0])' <<<"$ST")
  BID=${OTATOOLS_BUILD:-$(python3 -c 'import sys,json;print([t["last_known_good_build"] for t in json.load(sys.stdin)["targets"] if t["name"]==sys.argv[1]][0])' "$TGT" <<<"$ST")}
  echo "downloading otatools.zip (AOSP build $BID, $TGT, ~530 MB)" >&2
  curl -fsSL --retry 3 -o "$CACHE/otatools.zip" "https://ci.android.com/builds/submitted/$BID/$TGT/latest/raw/otatools.zip"
  rm -rf "$OT"; mkdir -p "$OT"
  unzip -q -o "$CACHE/otatools.zip" 'bin/ota_extractor' 'lib64/*' -d "$OT" && rm -f "$CACHE/otatools.zip"
  echo "$BID $TGT" >"$OT/BUILD"
fi

# 4. where each partition lives in the .bin: "<name> <old size> <new size> <source offset> <target offset>"
GPT=$(sgdisk -p "$BIN")
gpt() { awk -v n="$1" '$1 ~ /^[0-9]+$/ && $NF == n {print $2 * 512, ($3 - $2 + 1) * 512}' <<<"$GPT"; }
read -r SUPER _ < <(gpt super)
rm -rf "$CACHE"/work.*                             # left by a killed run (ponytail: assumes one run at a time)
W=$(mktemp -d "$CACHE/work.XXXX")
cleanup() { rm -rf "$W"; if [ -n "$NEW" ]; then rm -f "$NEW.part"; fi
  if [ -n "$INPLACE" ] && [ -e "$UNDO" ] && [ ! -e "$UNDO/done" ]; then echo "update stopped: putting $BIN back" >&2; revert
  elif [ -n "$DIRTY" ]; then echo "update stopped: $BIN is now half updated, a mix of two builds (no --undoable): restore it from a copy" >&2
    [ "$OTA_TYPE" != full ] || echo "or finish it, a full package applies to anything: FINGERPRINT='$FINGERPRINT' DATE_UTC=$DATE_UTC '$0' '$BIN' --in-place" >&2
  fi; }
trap cleanup EXIT
dd if="$BIN" of="$W/super_head" bs=1M iflag=skip_bytes skip="$SUPER" count=2 status=none
cp "$W/super_head" "$W/super_head.orig"            # grow edits super_head; --in-place keeps this one for --revert
PLAN="" GROWN=""
while read -r name old new; do
  loc=$(gpt "${name}_a"); lp=""
  if [ -z "$loc" ]; then lp=1; read -r o s < <(python3 "$ROOT/lib/lpinfo.py" "$W/super_head" "${name}_a"); loc="$((SUPER + o)) $s"; fi
  read -r off slot <<<"$loc"; dst=$off
  [ "$old" -le "$slot" ] || { echo "${name}_a: the package expects $old bytes, the image has $slot" >&2; exit 1; }
  if [ -n "$NEW$INPLACE" ] && [ "$new" -gt "$slot" ]; then   # outgrew its place (image files in out_dir have no layout)
    [ -n "$lp" ] || { echo "${name}_a: needs $new bytes, its GPT partition has $slot" >&2; exit 1; }
    read -r o s < <(python3 "$ROOT/lib/lpinfo.py" "$W/super_head" grow "${name}_a" "$new") || exit 1
    dst=$((SUPER + o)); GROWN=1; echo "${name}_a: $slot -> $new bytes, at super + $o" >&2
  fi
  PLAN+="$name $old $new $off $dst"$'\n'
done < <(python3 "$HERE/payload.py" parts "$ZIP")

# 5. apply partition by partition
IMG=""                                             # the image written into: the copy, or the .bin itself
if [ -n "$NEW" ]; then echo "copying $(basename "$BIN") -> $NEW" >&2; cp --reflink=auto --sparse=always "$BIN" "$NEW.part"; IMG=$NEW.part
elif [ -n "$INPLACE" ]; then
  [ -w "$BIN" ] || { echo "$BIN is not writable" >&2; exit 1; }
  rm -rf "$UNDO"                                   # an older update's undo data no longer fits the image
  if [ -n "$UNDOABLE" ]; then echo "updating $BIN in place; what it overwrites is saved in $UNDO" >&2
    mkdir "$UNDO"; cp "$W/super_head.orig" "$UNDO/super_head"
    { echo "super_head $SUPER"; awk 'NF {print $1 ".img", $5}' <<<"$PLAN"; } >"$UNDO/plan"
  else echo "updating $BIN in place, not undoable: a run that stops leaves it half updated" >&2; fi
  IMG=$BIN; DIRTY=1
else mkdir -p "$OUT"; rm -f "$OUT"/*.img; fi
# grown partitions: super's new metadata (all of it is in the head; the rest of the head is unchanged)
[ -z "$IMG" ] || [ -z "$GROWN" ] || dd if="$W/super_head" of="$IMG" bs=1M oflag=seek_bytes seek="$SUPER" conv=notrunc status=none
mkdir "$W/in" "$W/out"
while read -r name old new off dst; do
  [ -n "$name" ] || continue
  [ "$old" -eq 0 ] || dd if="$BIN" of="$W/in/$name.img" bs=4M iflag=skip_bytes,count_bytes skip="$off" count="$old" status=none
  "$X" --payload "$ZIP" --payload_offset "$POFF" --input_dir "$W/in" --output_dir "$W/out" --partitions "$name" </dev/null 2> >(grep -v 'INFO:' >&2)
  rm -f "$W/in/$name.img"
  read -r size want < <(python3 "$HERE/payload.py" target "$ZIP" "$name")
  if [ -n "$IMG" ]; then
    if [ -n "$UNDOABLE" ]; then                    # undo data first, complete and on disk before the write
      dd if="$BIN" of="$UNDO/$name.img.part" bs=4M iflag=skip_bytes,count_bytes skip="$dst" count="$size" conv=fsync status=none
      mv "$UNDO/$name.img.part" "$UNDO/$name.img"
    fi
    dd if="$W/out/$name.img" of="$IMG" bs=4M oflag=seek_bytes seek="$dst" conv=notrunc status=none
    rm -f "$W/out/$name.img"
    got=$(dd if="$IMG" bs=4M iflag=skip_bytes,count_bytes skip="$dst" count="$size" status=none | sha256sum | cut -d' ' -f1)
  else
    mv "$W/out/$name.img" "$OUT/$name.img"; got=$(sha256sum "$OUT/$name.img" | cut -d' ' -f1)
  fi
  [ "$got" = "$want" ] || { echo "$name: sha256 mismatch" >&2; exit 1; }
  printf '%-12s OK\n' "$name" >&2
done <<<"$PLAN"

if [ -n "$NEW" ]; then
  mv "$NEW.part" "$NEW"; echo "done: $NEW ($OTA_NFO)" >&2
elif [ -n "$INPLACE" ]; then
  sync "$BIN"; DIRTY=""; echo "done: $BIN is now $OTA_NFO" >&2
  [ -z "$UNDOABLE" ] || { touch "$UNDO/done"; echo "go back: --revert; free the space: delete $UNDO" >&2; }
else
  printf 'FROM=%s\nTO=%s\nPACKAGE=%s\n' "$FINGERPRINT" "$OTA_NFO" "$OTA_PKG" >"$OUT/BUILD_INFO"; echo "done: $OUT" >&2
fi
