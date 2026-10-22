#!/usr/bin/env bash
# Print the build identity of a Googlebook OS recovery image (no root, nothing extracted).
# Usage: tools/updater/buildinfo.sh <recovery.bin>      KEY=value lines, safe to eval
# Reads product_a's /etc/build.prop: GPT -> super -> LP metadata -> `dump.erofs --offset --cat`
# (erofs-utils >= 1.8: $EROFS_BIN, tools/bin, or PATH). The fingerprint comes from product:
# init derives ro.build.fingerprint from ro.product.*; system's build.prop only has the generic
# ro.system.build.fingerprint (Android/desktop_system/desktop:...).
set -euo pipefail
IMG=${1:?usage: $0 <recovery.bin>}
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../../lib/deps.sh
. "$HERE/../../lib/deps.sh"; deps_ensure updater   # sgdisk + dump.erofs >= 1.8 (built once)

u32() { od -An -tu4 -j "$1" -N4 "$IMG" | tr -d ' '; }
u64() { od -An -tu8 -j "$1" -N8 "$IMG" | tr -d ' '; }

# super: GPT partition
n=$(sgdisk -p "$IMG" 2>/dev/null | awk '$NF == "super" {print $1; exit}')
[ -n "$n" ] || { echo "no 'super' partition in $IMG" >&2; exit 1; }
super=$(( $(sgdisk -i "$n" "$IMG" | awk -F': ' '/First sector/ {split($2, a, " "); print a[1]}') * 512 ))

# product_a: LP metadata (system/core/fs_mgr/liblp/include/liblp/metadata_format.h), slot 0
[ "$(u32 $((super + 4096)))" = $((0x616C4467)) ] || { echo "no LP metadata in super" >&2; exit 1; }
h=$((super + 4096 + 2 * 4096))                     # reserved + 2 geometry copies
t=$((h + $(u32 $((h + 8)))))                       # tables follow the header
po=$(u32 $((h + 80))) pn=$(u32 $((h + 84))) ps=$(u32 $((h + 88)))
eo=$(u32 $((h + 92))) es=$(u32 $((h + 100)))
off=""
for ((k = 0; k < pn; k++)); do
  r=$((t + po + k * ps))
  name=$(dd if="$IMG" bs=1 skip=$r count=36 status=none | tr -d '\0')
  case $name in product_a|product)
    off=$((super + $(u64 $((t + eo + $(u32 $((r + 40))) * es + 12))) * 512)); break ;; esac
done
[ -n "$off" ] || { echo "no product partition in super" >&2; exit 1; }

DUMP=""
for d in "${EROFS_BIN:-}" "$HERE/../bin"; do [ -n "$d" ] && [ -x "$d/dump.erofs" ] && { DUMP=$d/dump.erofs; break; }; done
DUMP=${DUMP:-$(command -v dump.erofs)} || { echo "dump.erofs not found (tools/build-erofs-utils.sh, or set EROFS_BIN)" >&2; exit 1; }
props=$("$DUMP" --offset="$off" --cat --path=/etc/build.prop "$IMG")

prop() { printf '%s\n' "$props" | sed -n "s/^$1=//p" | head -1; }
for kv in FINGERPRINT=ro.product.build.fingerprint BRAND=ro.product.product.brand \
          MANUFACTURER=ro.product.product.manufacturer MODEL=ro.product.product.model \
          DEVICE=ro.product.product.device PRODUCT=ro.product.product.name BUILD_ID=ro.build.id \
          INCREMENTAL=ro.build.version.incremental RELEASE=ro.build.version.release \
          SDK=ro.build.version.sdk SECURITY_PATCH=ro.build.version.security_patch DATE_UTC=ro.build.date.utc; do
  printf '%s=%q\n' "${kv%%=*}" "$(prop "${kv#*=}")"
done
