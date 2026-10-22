#!/usr/bin/env bash
# Apply the update Google offers a Googlebook recovery image, locally (no device, no full download).
# Usage: tools/updater/ota-update.sh <recovery.bin> [out_dir]         updated <partition>.img files
#        tools/updater/ota-update.sh <recovery.bin> --bin <new.bin>   updated copy of the whole image
#   out_dir defaults to out/ota-update. --bin never overwrites: it refuses an existing file and
#   builds <new.bin>.part, renamed only once every partition checks out.
# Steps: buildinfo.sh (fingerprint + build timestamp) -> ota-check.sh (the delta Google offers that
# build) -> download it (cached; the file name is its SHA-1, checked) and AOSP's prebuilt
# ota_extractor (ci.android.com otatools.zip, x86_64 Linux, cached) -> for each partition in the
# delta: cut its source out of the .bin (GPT *_a or super *_a, no root), apply it with ota_extractor
# (update_engine's code, so VABC LZ4DIFF ops work), write it out and check it against the payload's
# target SHA-256 (with --bin: read back from the new image). One partition at a time, so temporary
# space peaks at ~2x the largest partition (~4 GB) and no .img files are left behind with --bin.
# Works because the .bin is the stock build, where the delta applies cleanly. The image layout is
# kept: a partition whose new size exceeds its slot stops the run (would need a super resize).
# Env: CHURRO_OTA_CACHE (default out/ota-cache), OTATOOLS_BUILD=<ci build id> to pin otatools,
#      FINGERPRINT + DATE_UTC to skip buildinfo.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
BIN="" OUT="" NEW=""
while [ $# -gt 0 ]; do
  case $1 in
    --bin) shift; NEW=${1:?--bin needs a file name} ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) if [ -z "$BIN" ]; then BIN=$1; elif [ -z "$OUT" ]; then OUT=$1; else echo "too many arguments" >&2; exit 1; fi ;;
  esac; shift
done
[ -f "$BIN" ] || { echo "usage: ota-update.sh <recovery.bin> [out_dir | --bin <new.bin>]" >&2; exit 1; }
OUT=${OUT:-$ROOT/out/ota-update}
CACHE=${CHURRO_OTA_CACHE:-$ROOT/out/ota-cache}
for t in python3 curl unzip sgdisk dd sha256sum sha1sum; do command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }; done
if [ -n "$NEW" ]; then [ ! -e "$NEW" ] || { echo "$NEW exists, not overwriting" >&2; exit 1; }; mkdir -p "$(dirname "$NEW")"; fi
mkdir -p "$CACHE"

# 1-2. what does Google offer this build?
[ -n "${FINGERPRINT:-}" ] && [ -n "${DATE_UTC:-}" ] || eval "$("$HERE/buildinfo.sh" "$BIN")"
eval "$(OTA_TS=$DATE_UTC "$HERE/ota-check.sh" "$FINGERPRINT")"
[ -n "$DELTA_PKG" ] || { echo "no delta offered for $FINGERPRINT" >&2; exit 1; }
echo "update: $FINGERPRINT -> $DELTA_NFO" >&2

# 3a. the delta (content-addressed: name == sha1)
ZIP=$CACHE/${DELTA_PKG##*/}; SHA=$(basename "$ZIP" .zip)
if [ ! -f "$ZIP" ] || [ "$(sha1sum "$ZIP" | cut -d' ' -f1)" != "$SHA" ]; then
  echo "downloading ${DELTA_PKG##*/}" >&2; curl -fsSL --retry 3 -o "$ZIP.part" "$DELTA_PKG" && mv "$ZIP.part" "$ZIP"
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

# 4. where each partition lives in the .bin: "<name> <old size> <new size> <byte offset> <slot size>"
GPT=$(sgdisk -p "$BIN")
gpt() { awk -v n="$1" '$1 ~ /^[0-9]+$/ && $NF == n {print $2 * 512, ($3 - $2 + 1) * 512}' <<<"$GPT"; }
read -r SUPER _ < <(gpt super)
rm -rf "$CACHE"/work.*                             # left by a killed run (ponytail: assumes one run at a time)
W=$(mktemp -d "$CACHE/work.XXXX")
cleanup() { rm -rf "$W"; if [ -n "$NEW" ]; then rm -f "$NEW.part"; fi; }
trap cleanup EXIT
dd if="$BIN" of="$W/super_head" bs=1M iflag=skip_bytes skip="$SUPER" count=2 status=none
PLAN=""
while read -r name old new; do
  loc=$(gpt "${name}_a")
  if [ -z "$loc" ]; then read -r o s < <(python3 "$ROOT/lib/lpinfo.py" "$W/super_head" "${name}_a"); loc="$((SUPER + o)) $s"; fi
  read -r off slot <<<"$loc"
  [ "$new" -le "$slot" ] && [ "$old" -le "$slot" ] || { echo "${name}_a: needs $new bytes, slot has $slot (layout change not supported)" >&2; exit 1; }
  PLAN+="$name $old $new $off"$'\n'
done < <(python3 "$HERE/payload.py" parts "$ZIP")

# 5. apply partition by partition
if [ -n "$NEW" ]; then echo "copying $(basename "$BIN") -> $NEW" >&2; cp --reflink=auto --sparse=always "$BIN" "$NEW.part"
else mkdir -p "$OUT"; rm -f "$OUT"/*.img; fi
mkdir "$W/in" "$W/out"
while read -r name old new off; do
  [ -n "$name" ] || continue
  [ "$old" -eq 0 ] || dd if="$BIN" of="$W/in/$name.img" bs=4M iflag=skip_bytes,count_bytes skip="$off" count="$old" status=none
  "$X" --payload "$ZIP" --payload_offset "$POFF" --input_dir "$W/in" --output_dir "$W/out" --partitions "$name" </dev/null 2> >(grep -v 'INFO:' >&2)
  rm -f "$W/in/$name.img"
  read -r size want < <(python3 "$HERE/payload.py" target "$ZIP" "$name")
  if [ -n "$NEW" ]; then
    dd if="$W/out/$name.img" of="$NEW.part" bs=4M oflag=seek_bytes seek="$off" conv=notrunc status=none
    rm -f "$W/out/$name.img"
    got=$(dd if="$NEW.part" bs=4M iflag=skip_bytes,count_bytes skip="$off" count="$size" status=none | sha256sum | cut -d' ' -f1)
  else
    mv "$W/out/$name.img" "$OUT/$name.img"; got=$(sha256sum "$OUT/$name.img" | cut -d' ' -f1)
  fi
  [ "$got" = "$want" ] || { echo "$name: sha256 mismatch" >&2; exit 1; }
  printf '%-12s OK\n' "$name" >&2
done <<<"$PLAN"

if [ -n "$NEW" ]; then
  mv "$NEW.part" "$NEW"; echo "done: $NEW ($DELTA_NFO)" >&2
else
  printf 'FROM=%s\nTO=%s\nPACKAGE=%s\n' "$FINGERPRINT" "$DELTA_NFO" "$DELTA_PKG" >"$OUT/BUILD_INFO"; echo "done: $OUT" >&2
fi
