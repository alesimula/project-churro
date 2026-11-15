#!/usr/bin/env bash
# Distro-like driver coverage: every module our kernel build has and the image doesn't (the
# profile's distro module set, nouveau, ...) joins vendor_dlkm. ueventd loads vendor_dlkm modules
# by device alias (modules.alias), so each machine only loads what its hardware matches.
# ABI gate: our modules link against the image's own modules (Google's builds) wherever those
# exist, so depmod checks every symbol and CRC they need against the image's modules + our
# vmlinux (= Google's, prepare.sh's kABI check). A module whose needs aren't met is left out,
# and so is everything that needs it. Where a Google module lacks a symbol and our build of it
# exports everything Google's does with identical CRCs (+ more), ours replaces it (e.g.
# drm_ttm_helper: Google's has no fbdev console, nouveau needs it).
set -euo pipefail
T=$1; D=$T/lib/modules; F=$(dirname "$0"); VP=/vendor/lib/modules
K=${CHURRO_KERNEL:?drivers-extra needs the Churro kernel (--kernel)}
MD=$(ls -d "$K"/modroot/lib/modules/*/); rel=$(basename "$MD")
SV=$K/Module.symvers
if [ ! -f "$SV" ]; then   # kernel cache dirs from before prepare.sh copied it: the build tree's
  b=$(basename "$K"); p=${b#kernel-}; prof=${p%%-*}; bid=${p#*-}; bid=${bid%%-*}
  SV=$(dirname "$K")/src-$bid/common/out-kernel-$prof/Module.symvers
fi
[ -f "$SV" ] || { echo "drivers-extra: Module.symvers of the Churro kernel not found" >&2; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export LC_ALL=C
n() { basename "$1" .ko | tr - _; }

# Intel GPUs the image's xe driver binds (device IDs, upper-case hex as in modules.alias). Our i915
# must never load for those: it wedged Arrow Lake next to xe (docs/02). Its aliases are filtered
# below; the list also goes to the boot menu (esp.sh: native for these, mesa for older Intel).
modinfo -F alias "$D/xe.ko" 2>/dev/null | sed -nE 's/^pci:v00008086d0000([0-9A-F]{4}).*/\1/p' | sort -u > "$W/xeids"
# fail closed: an empty list would let i915 claim every Gen12+ GPU again (the Arrow Lake regression)
[ -s "$W/xeids" ] || { echo "drivers-extra: no device IDs in $D/xe.ko - refusing to ship i915 unfiltered" >&2; exit 1; }
[ -z "${CHURRO_XE_IDS:-}" ] || cp "$W/xeids" "$CHURRO_XE_IDS"

# the image's modules: vendor_dlkm (here) + system_dlkm (GKI modules, other partition of super)
read -r off size < <(python3 "$CHURRO_HERE/lib/lpinfo.py" "$CHURRO_SUPER" system_dlkm_a)
L=$(losetup -f --show -r -o "$off" --sizelimit "$size" "$CHURRO_SUPER")
"$EROFS_BIN/fsck.erofs" --extract="$W/sys" "$L" >/dev/null || true; losetup -d "$L"
mapfile -t SKIP < <(grep -vE '^\s*(#|$)' "$F/skip.txt")
R=$W/dm/lib/modules/$rel; mkdir -p "$R/vendor" "$R/system"
declare -A IMG OURS
for f in "$D"/*.ko; do IMG[$(n "$f")]=v; ln -s "$f" "$R/vendor/"; done
while read -r f; do IMG[$(n "$f")]=s; ln -sf "$f" "$R/system/"; done < <(find "$W/sys" -name '*.ko')
while read -r f; do OURS[$(n "$f")]=$f; done < <(find "$MD" -name '*.ko')
for m in "${!OURS[@]}"; do
  [ -n "${IMG[$m]:-}" ] && continue
  for s in "${SKIP[@]}"; do case $m in $s) continue 2 ;; esac; done
  ln -s "${OURS[$m]}" "$R/vendor/"; echo "$m"
done | sort > "$W/new"

# exports <ko>: "sym crc" (__crc_<sym> symbols point into __kcrctab*)
sec() { readelf -SW "$1" | sed 's/^ *\[ *//; s/\]//' | awk -v n="$2" '$2 ~ n {print $1, $5, $6}'; }
exports() {
  local f=$1 idx off size
  sec "$f" '^__kcrctab' | while read -r idx off size; do
    od -An -tx4 -v -w4 -j $((16#$off)) -N $((16#$size)) "$f" | awk -v i="$idx" '{print i ":" (NR-1)*4, $1}'
  done | sort > "$W/val"
  readelf -sW "$f" | awk '$8 ~ /^__crc_/ {print $7, $2, substr($8, 7)}' | while read -r ndx v s; do
    echo "$ndx:$((16#$v)) $s"; done | sort > "$W/sym"
  join "$W/sym" "$W/val" | awk '{print $2, $3}' | sort
}
# replaceable <sym>: the Google vendor module our build exports <sym> from, if ours can stand in
replaceable() {
  local m; m=$(awk -v s="$1" '$2 == s {print $3; exit}' "$SV"); m=$(n "${m:-x}")
  [ "${IMG[$m]:-}" = v ] && [ -n "${OURS[$m]:-}" ] || return 1
  exports "${OURS[$m]}" > "$W/o"; exports "$D/$(basename "${OURS[$m]}")" > "$W/g" 2>/dev/null || return 1
  comm -23 "$W/g" "$W/o" | grep -q . && return 1
  echo "$m"
}
# depmod -e: unknown symbols / CRC mismatches -> fix by replacement or leave the module out; repeat
declare -A REPL; : > "$W/dropped"
for i in $(seq 1 40); do
  depmod -b "$W/dm" -e -E "$SV" "$rel" 2> "$W/warn" || true
  sed -nE 's#.*/vendor/([^ /]+)\.ko (needs unknown symbol|disagrees about version of symbol) ([^ ]+).*#\1 \3 \2#p' "$W/warn" > "$W/bad"
  changed=0
  while read -r f s why _; do
    m=$(n "$f"); grep -qx "$m" "$W/new" || continue      # Google's own modules: not ours to judge
    if [ "$why" = needs ] && r=$(replaceable "$s"); then
      [ -n "${REPL[$r]:-}" ] || { REPL[$r]=1; rm -f "$R/vendor/$(basename "${OURS[$r]}")"; ln -s "${OURS[$r]}" "$R/vendor/"; changed=1; }
      continue
    fi
    [ -e "$R/vendor/$f.ko" ] || continue
    rm -f "$R/vendor/$f.ko"; sed -i "/^$m\$/d" "$W/new"; echo "$m ($why $s)" >> "$W/dropped"; changed=1
  done < "$W/bad"
  [ $changed = 1 ] || break
done
for r in "${!REPL[@]}"; do echo "   vendor_dlkm: $r.ko replaced by our build (same exports and CRCs, plus what our modules need)"; echo "$r" >> "$W/new"; done

# install with the label vendor modules have
lbl=$(getfattr --absolute-names --only-values -n security.selinux "$(ls "$D"/*.ko | head -1)")
while read -r m; do
  f=${OURS[$m]}; b=$(basename "$f"); echo "$b"
  install -m 0644 -o root -g root "$f" "$D/$b"; setfattr -n security.selinux -v "$lbl" "$D/$b"
done < "$W/new" | sort -u > "$W/ours"

# modules.dep lines (paths as the image writes them), aliases, softdeps for what we added;
# rewritten in place so the files keep their SELinux labels
SP=$(grep -oE '/system[a-z_]*/lib/modules/[^ :]*/' "$D/modules.dep" | head -1 || true); SP=${SP:-/system/lib/modules/}
sed -E "s#(^| )vendor/#\1$VP/#g; s#(^| )system/#\1$SP#g" "$R/modules.dep" |
  grep -F -f <(sed "s#^#$VP/#; s#\$#:#" "$W/ours") > "$W/dep.new" || true
grep -v -F -f <(sed "s#^#$VP/#; s#\$#:#" "$W/ours") "$D/modules.dep" > "$W/dep" || true
cat "$W/dep" "$W/dep.new" > "$D/modules.dep"
{ cat "$D/modules.alias"
  while read -r b; do m=$(n "$b"); modinfo -F alias "$D/$b" 2>/dev/null |
    if [ "$m" = i915 ]; then grep -viF -f <(sed 's/^/pci:v00008086d0000/' "$W/xeids") || true; else cat; fi |
    sed "s/^/alias /; s/\$/ $m/"; done < "$W/ours"
} | awk '!seen[$0]++' > "$W/alias"
cat "$W/alias" > "$D/modules.alias"
# AMD GPUs radeon.ko claims (up to GFX7: amdgpu gives those only its legacy display path, which
# drm_hwcomposer can't use) -> the boot menu keeps them off the amd mode (esp.sh)
[ -z "${CHURRO_RADEON_IDS:-}" ] || sed -nE 's/^alias pci:v00001002d0000([0-9A-F]{4}).* radeon$/\1/p' "$D/modules.alias" | sort -u > "$CHURRO_RADEON_IDS"
if [ -s "$R/modules.softdep" ] && [ -f "$D/modules.softdep" ]; then
  grep -F -f <(sed 's/\.ko$//; s/-/_/g; s/^/softdep /; s/$/ /' "$W/ours") "$R/modules.softdep" |
    cat "$D/modules.softdep" - | awk '!seen[$0]++' > "$W/sd" || true
  cat "$W/sd" > "$D/modules.softdep"
fi
grep -qx i915.ko "$W/ours" && echo "   vendor_dlkm: i915 for older Intel GPUs: $(grep -c ' i915$' "$D/modules.alias") device IDs ($(wc -l < "$W/xeids") left to xe)"
echo "   vendor_dlkm: +$(wc -l < "$W/ours") modules from our kernel build ($(cd "$D" && du -cm $(cat "$W/ours") | tail -1 | cut -f1) MiB), $(wc -l < "$W/dropped") left out by the ABI check"
sed 's/^/     left out: /' "$W/dropped"
