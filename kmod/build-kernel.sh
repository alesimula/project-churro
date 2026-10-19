#!/usr/bin/env bash
# Build a "Churro kernel": Google's own GKI source at the image's exact commit, with the image's
# own config, plus extra drivers and without KMI symbol trimming. Same release string, same
# CRCs (gendwarfksyms over identical types) -> the image's vendor_dlkm/system_dlkm modules keep
# loading, but we can now add drivers the stock GKI can't take as modules (i915, simpledrm, ahci...).
#
# Usage: kmod/build-kernel.sh <ack src> <clang dir> <rust dir> <bindgen dir> <ikconfig> <kernel release> <profile> <out dir>
#   profile = kmod/profiles/<name>.conf with:  Y="SYSFB_SIMPLEFB ..."  M="DRM_I915 ..."  N="..."
set -euo pipefail
SRC=$1 CLANG=$2 RUST=$3 BINDGEN=$4 CFG=$5 REL=$6 PROF=$7 OUT=$8
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../versions.env"   # ARCH_LINUX_CONFIG_TAG, used by the profile
Y="" M="" N=""; . "$HERE/profiles/$PROF.conf"
export PATH="$CLANG/bin:$RUST/bin:$BINDGEN:$PATH"
# bindgen must use the Android clang's libclang, not a distro one (unknown -W options otherwise)
export LIBCLANG_PATH="$CLANG/lib"
O=$SRC/out-kernel-$PROF; mkdir -p "$O"
# kmod/patches/*.patch: small built-in fixes (no exported types touched -> CRCs unchanged).
# Applied copies are recorded in $SRC/.churro-applied: a patch that was edited or deleted since
# is reversed first, so the cached source tree always matches kmod/patches.
A=$SRC/.churro-applied; mkdir -p "$A"
for a in "$A"/*.patch; do
  [ -e "$a" ] || continue
  cmp -s "$a" "$HERE/patches/${a##*/}" || { patch -d "$SRC" -p1 -R -s < "$a"; rm "$a"; }
done
for p in "$HERE"/patches/*.patch; do
  [ -e "$p" ] && [ ! -e "$A/${p##*/}" ] || continue
  patch -d "$SRC" -p1 -s -N < "$p"; cp "$p" "$A/"
done
# KBUILD_GENDWARFKSYMS_STABLE: GKI computes symbol CRCs in "--stable" (kABI-aware) mode; without
# it every CRC touching a struct differs and vendor modules fail with "disagrees about version".
MK=(make -C "$SRC" -j"$(nproc)" LLVM=1 LLVM_IAS=1 ARCH=x86_64 O="$O" KBUILD_GENDWARFKSYMS_STABLE=1)
cp "$CFG" "$O/.config"; cp "$O/.config" "$O/.config.orig"
SC() { "$SRC/scripts/config" --file "$O/.config" "$@"; }
# same release string as the GKI build so vermagic matches the image's prebuilt modules
# (keep LOCALVERSION_AUTO: MODULE_SCMVERSION depends on it and changes struct module, i.e. the
#  module_layout CRC every vendor module checks; a source tarball has no SCM info to append anyway)
SC --set-str LOCALVERSION "-${REL#*-}"
# keep every export (no KMI trimming); unsigned (vendor) modules allowed
SC -d TRIM_UNUSED_KSYMS -d MODULE_SIG_FORCE
# Trust Google's GKI module signing key (from the image's vmlinux, tools/extract-certs.sh): GKI
# modules carry "protected" export flags baked in by Google's modpost, and a module whose
# signature we can't verify may not use them (system_dlkm zram -> zsmalloc refused otherwise).
[ -n "${CHURRO_GKI_CERTS:-}" ] && SC --set-str SYSTEM_TRUSTED_KEYS "$(realpath "$CHURRO_GKI_CERTS")"
for c in $Y; do SC -e "$c"; done; for c in $M; do SC -m "$c"; done; for c in $N; do SC -d "$c"; done
"${MK[@]}" olddefconfig >/dev/null
# distro module set (profile DISTRO_*): options the distro builds as modules that we don't have
# yet, limited to driver directories (Kconfig file that defines the symbol)
if [ -n "${DISTRO_CONFIG:-}" ]; then
  # cached per URL: a new ARCH_LINUX_CONFIG_TAG downloads its config again
  [ -s "$O/distro.config" ] && [ "$(cat "$O/distro.url" 2>/dev/null)" = "$DISTRO_CONFIG" ] ||
    { curl -fsSL --retry 3 -o "$O/distro.config" "$DISTRO_CONFIG"; echo "$DISTRO_CONFIG" > "$O/distro.url"; }
  (cd "$SRC" && grep -rH -E '^(menu)?config [A-Za-z0-9_]+' --include='Kconfig*' . ) |
    sed -E 's#^\./([^:]+):(menu)?config ([A-Za-z0-9_]+).*#\3 \1#' | sort -u -k1,1 > "$O/sym2file"
  grep -oE '^CONFIG_[A-Za-z0-9_]+=m$' "$O/distro.config" | sed 's/^CONFIG_//; s/=m$//' | sort -u |
    join - "$O/sym2file" | awk -v dirs="$DISTRO_DIRS" -v deny="$DISTRO_DENY" '$2 ~ dirs && $1 !~ deny {print $1}' |
    while read -r c; do grep -qE "^CONFIG_$c=[ym]$" "$O/.config" || echo "$c"; done > "$O/distro.add"
  cp "$O/.config" "$O/.config.predistro"
  # A module can switch on (select) built-in options. Those that change core structs (fields
  # under #ifdef in netdevice.h, i2c.h, ...) change the CRC of hundreds of GKI exports, so
  # Google's prebuilt modules would stop loading: leave out whatever pulls them in, following
  # select chains, until no such option is left.
  (cd "$SRC" && find . -name 'Kconfig*' -not -path './out*' | xargs awk '/^(menu)?config /{c=$2}
    /^[ \t]+(select|imply)[ \t]+[A-Za-z0-9_]+/{print $2, c}') | sort -u > "$O/selects"   # "selected selector"
  # options core headers test (struct fields, mostly)
  (cd "$SRC" && cat include/linux/{netdevice,skbuff,sched,fs,mm_types,device,i2c,pci,usb,cgroup-defs,blkdev,blk_types,bio,interrupt,irq,workqueue,timer,module}.h \
     include/linux/sched/*.h include/net/{sock,net_namespace,dst}.h include/net/netns/*.h) |
    grep -oE 'CONFIG_[A-Za-z0-9_]+' | sed 's/^CONFIG_//' | sort -u > "$O/coresyms"
  for i in $(seq 1 20); do
    cp "$O/.config.predistro" "$O/.config"; SC $(sed 's/^/-m /' "$O/distro.add"); "${MK[@]}" olddefconfig >/dev/null
    grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$O/.config" | grep -vxFf "$O/.config.predistro" | sed 's/^CONFIG_//; s/=y$//' | sort > "$O/newy"
    comm -12 "$O/newy" "$O/coresyms" | grep -vxF -f <(printf '%s\n' ${DISTRO_BUILTIN_OK:-} x) > "$O/forbid" || true
    [ -s "$O/forbid" ] || break
    echo "   distro modules: core built-in side effects: $(tr '\n' ' ' < "$O/forbid")"
    # walk the select graph back to modules in distro.add; intermediate selectors (enabled by us,
    # not in the list) are forbidden too
    sort -u "$O/forbid" > "$O/walk"; before=$(wc -l < "$O/distro.add")
    while [ -s "$O/walk" ]; do
      join "$O/walk" "$O/selects" 2>/dev/null | awk '{print $2}' | sort -u > "$O/sel"; : > "$O/walk"
      while read -r t; do
        if grep -qx "$t" "$O/distro.add"; then sed -i "/^$t\$/d" "$O/distro.add"; echo "     leaving out $t"
        elif grep -qE "^CONFIG_$t=[ym]$" "$O/.config" && ! grep -qE "^CONFIG_$t=[ym]$" "$O/.config.predistro" && ! grep -qx "$t" "$O/forbid"; then
          echo "$t" >> "$O/forbid"; echo "$t" >> "$O/walk"; fi
      done < "$O/sel"
      sort -u "$O/walk" -o "$O/walk"
    done
    [ "$(wc -l < "$O/distro.add")" -lt "$before" ] || { echo "distro modules: can't tell which module enables $(tr '\n' ' ' < "$O/forbid")- add it to DISTRO_DENY" >&2; exit 1; }
  done
  # never weaken a built-in option (a module dependency can downgrade y to m)
  down=$(grep -E '=y$' "$O/.config.predistro" | grep -vxFf "$O/.config" || true)
  [ -z "$down" ] || { echo "distro modules would weaken built-in options:" >&2; echo "$down" >&2; exit 1; }
  echo "== distro modules: $(wc -l < "$O/distro.add") options added"
fi
for f in $(grep -oE '_LIST="[^"]+"' "$O/.config" | cut -d'"' -f2); do [ -e "$SRC/$f" ] || : > "$SRC/$f"; done
echo "== config delta vs shipped kernel (built-in options; $(grep -c '=m$' "$O/.config") modules):"
diff <(grep -E '^CONFIG_' "$O/.config.orig" | grep -v '=m$' | sort) <(grep -E '^CONFIG_' "$O/.config" | grep -v '=m$' | sort) | grep -E '^[<>]' || true
echo "$(cat "$O/include/config/kernel.release" 2>/dev/null)"
"${MK[@]}" bzImage modules 2>&1 | grep -E 'error|Error|WARNING: modpost' | head -40 || true
mkdir -p "$OUT/modules"
cp "$O/arch/x86/boot/bzImage" "$OUT/kernel"
cat "$O/include/config/kernel.release" > "$OUT/kernel.release"
"${MK[@]}" INSTALL_MOD_PATH="$OUT/modroot" INSTALL_MOD_STRIP=1 modules_install >/dev/null
echo "built $(cat "$OUT/kernel.release") -> $OUT"
