#!/usr/bin/env bash
# Self-check for the version selection (docs/09-version-support.md): the patch folders (kernel,
# minigbm, Mesa: lib/versions.sh) and the image pin files read by versions.env. No image, no
# root, no network.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
. "$HERE/lib/versions.sh"
fail() { echo "FAIL $1"; exit 1; }

mkdir -p "$T/p/6.18" "$T/p/6.18-ab17000000" "$T/p/6.24" "$T/p/notes"
pick() { basename "$(kernel_patch_dir "$T/p" "$1" 2>/dev/null)"; }
while read -r rel want; do
  [ "$(pick "$rel")" = "$want" ] || fail "$rel -> $(pick "$rel"), expected $want"
done <<'T'
6.18.21-android17-5-g0e2640c903c1-ab16560873 6.18
6.18.40-android17-5-gabc-ab17000000 6.18-ab17000000
6.18.44-android17-6-gabc-ab17500000 6.18-ab17000000
6.18.21-custom 6.18
6.20.3-android18-1-gabc-ab18000000 6.18-ab17000000
6.24.1-android18-2-gabc-ab19000000 6.24
7.1.0-android19-1-gabc-ab30000000 6.24
T
! kernel_patch_dir "$T/p" 6.12.9-android16-3-gabc-ab15000000 >/dev/null 2>&1 || fail "an older series than any folder must fail"
kernel_patch_dir "$T/p" 6.20.3-android18-1-gabc-ab18000000 2>&1 >/dev/null | grep -q "has no folder for 6.20: using 6.18-ab17000000" || fail "no notice for a borrowed series"
[ "$(basename "$(kernel_patch_dir "$HERE/kmod/patches" 6.18.21-android17-5-g0e2640c903c1-ab16560873)")" = 6.18 ] || fail "the repo's own folders"
echo "ok kernel patch folders"

# the same rule for minigbm (Android API + image build) and Mesa (release a.b + c) patch folders
mkdir -p "$T/m/api37" "$T/m/api37-16900000" "$T/m/api39" "$T/g/26.2" "$T/g/26.2-5" "$T/g/26.10"
vd() { basename "$(version_dir "$T/$1" "$2" "$3" 2>/dev/null)"; }
while read -r root ser num want; do
  [ "$(vd "$root" "$ser" "$num")" = "$want" ] || fail "$root $ser $num -> $(vd "$root" "$ser" "$num"), expected $want"
done <<'T'
m api37 16833189 api37
m api37 16900000 api37-16900000
m api38 17500000 api37-16900000
m api39 1 api39
m api40 0 api39
g 26.2 4 26.2
g 26.2 5 26.2-5
g 26.3 0 26.2-5
g 26.10 1 26.10
g 27.0 0 26.10
T
! version_dir "$T/m" api36 99999999 >/dev/null 2>&1 || fail "an older release than any folder must fail"
( . "$HERE/versions.env"; [ "$(basename "$(version_dir "$HERE/gfx/mesa-patches" "${MESA_VER%.*}" "${MESA_VER##*.}")")" = "${MESA_VER%.*}" ] ) || fail "the repo's Mesa patch folder"
[ "$(basename "$(version_dir "$HERE/gfx/minigbm-patches" api37 16833189)")" = api37 ] || fail "the repo's minigbm patch folder"
echo "ok minigbm and Mesa patch folders"

# pin files: a copy of versions.env beside made-up versions/api99*.env
mkdir "$T/v" "$T/v/versions"; cp "$HERE/versions.env" "$T/v/"
echo ': "${A:=base}"; : "${B:=base}"; : "${C:=base}"' > "$T/v/versions/api99.env"
echo ': "${A:=from200}"; : "${B:=from200}"'           > "$T/v/versions/api99-200.env"
echo ': "${A:=from300}"'                               > "$T/v/versions/api99-300.env"
echo ': "${A:=other}"'                                 > "$T/v/versions/api98.env"
pins() { ( set -eu; export CHURRO_API=$1 CHURRO_IMAGE_BUILD=$2; . "$T/v/versions.env"; echo "$A $B $C $MESA_VER" ); }
MV=$(. "$HERE/versions.env"; echo "$MESA_VER")
[ "$(pins 99 100)" = "base base base $MV" ] || fail "build before any override: $(pins 99 100)"
[ "$(pins 99 250)" = "from200 from200 base $MV" ] || fail "build 250: $(pins 99 250)"
[ "$(pins 99 300)" = "from300 from200 base $MV" ] || fail "build 300: $(pins 99 300)"
[ "$(A=mine pins 99 300)" = "mine from200 base $MV" ] || fail "the environment must win"
! pins 97 1 >/dev/null 2>&1 || fail "a release without a pin file must fail"
( set -eu; unset CHURRO_API; . "$T/v/versions.env"; [ -z "${A:-}" ] ) || fail "no CHURRO_API: release pins must stay unset"
( set -eu; export CHURRO_API=37 CHURRO_IMAGE_BUILD=16833189; . "$HERE/versions.env"
  : "$CHURRO_EMU_URL$CHURRO_EMU_SHA1$BORINGSSL_REV$BORINGSSL_HTTPENGINE_REV$BORINGSSL_HTTPENGINE_FOR$MINIGBM_REV$MINIGBM_INTERFACES_REV$CHURRO_TESTED_BUILD" ) || fail "the repo's api37 pins"
echo "ok image pin files"
echo "all passed"
