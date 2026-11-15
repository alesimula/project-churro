#!/usr/bin/env bash
# Self-check for splash.c's TGA decoder and scaler (no root): renders splash.tga for a few screens
# and checks a point on the red arc (red), the C's opening and the corners (black). The point is
# derived from mk-splash.sh's layout: logo box 593 px of the 1600 px canvas, red at canvas (593, 800).
set -euo pipefail
F="$(dirname "$(realpath "$0")")"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cc -O2 -Wall -o "$W/splash" "$F/splash.c"
px() {  # px <ppm> <w> <x> <y> -> "r g b"
  local hdr; hdr=$(head -c 32 "$1" | head -3 | wc -c)
  od -An -tu1 -j $((hdr + ($4 * $2 + $3) * 3)) -N3 "$1" | xargs; }
fail=0
for t in "1366 768 32" "1920 1080 16" "800 600 24" "768 1366 32" "3840 2160 32"; do
  set -- $t; w=$1 h=$2 bpp=$3
  "$W/splash" --test "$F/splash.tga" $w $h $bpp "$W/o.ppm"
  s=$(( w < h ? w : h )); x0=$(( (w - s) / 2 )) y0=$(( (h - s) / 2 ))
  read -r r g b <<< "$(px "$W/o.ppm" $w $((x0 + 593 * s / 1600)) $((y0 + 800 * s / 1600)))"
  read -r cr cg cb <<< "$(px "$W/o.ppm" $w $((w / 2)) $((h / 2)))"
  read -r kr kg kb <<< "$(px "$W/o.ppm" $w $((w - 1)) $((h - 1)))"
  read -r lr lg lb <<< "$(px "$W/o.ppm" $w 0 0)"
  if [ $r -gt 180 ] && [ $g -lt 120 ] && [ $b -lt 120 ] && [ $((cr + cg + cb + kr + kg + kb + lr + lg + lb)) -lt 30 ]; then
    echo "ok $t (red arc $r,$g,$b)"
  else echo "FAIL $t: arc $r,$g,$b centre $cr,$cg,$cb corners $kr,$kg,$kb $lr,$lg,$lb"; fail=1; fi
done
[ -z "${KEEP:-}" ] || cp "$W/o.ppm" "$KEEP"
exit $fail
