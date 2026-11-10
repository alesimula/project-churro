#!/usr/bin/env bash
# check-sepolicy.sh <super.img>: compile the image's SELinux policy the way init does at boot
# (features add rules to vendor_sepolicy.cil and drop the precompiled policy, so init compiles
# the CIL on the device: a broken rule = an image that doesn't boot). Fails the build instead.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); SUPER=$1; B=$HERE/bin
X=$(mktemp -d); trap 'rm -rf "$X"' EXIT
get() {  # get <partition> <path>: file from the patched partition, or nothing
  local off size L
  read -r off size < <(python3 "$HERE/../lib/lpinfo.py" "$SUPER" "${1}_a" 2>/dev/null) || return 0
  L=$(losetup -f --show -r -o "$off" --sizelimit "$size" "$SUPER")
  "${EROFS_BIN:-$B}/dump.erofs" --cat --path="$2" "$L" > "$X/f" 2>/dev/null && [ -s "$X/f" ] && mv "$X/f" "$X/$1.$(basename "$2")" || true
  losetup -d "$L"; [ -f "$X/$1.$(basename "$2")" ] && echo "$X/$1.$(basename "$2")" || true
}
V=$(cat "$(get vendor /etc/selinux/plat_sepolicy_vers.txt)")
# same files and order as init (system/core/init/selinux.cpp); -N: init skips neverallow checks
args=("$(get system /system/etc/selinux/plat_sepolicy.cil)" -m -M true -G -N -c 30
      "$(get system /system/etc/selinux/mapping/$V.cil)")
for f in "system /system/etc/selinux/mapping/$V.compat.cil" \
         "system_ext /etc/selinux/system_ext_sepolicy.cil" "system_ext /etc/selinux/mapping/$V.cil" \
         "product /etc/selinux/product_sepolicy.cil" "product /etc/selinux/mapping/$V.cil" \
         "vendor /etc/selinux/plat_pub_versioned.cil" "vendor /etc/selinux/vendor_sepolicy.cil" \
         "odm /etc/selinux/odm_sepolicy.cil"; do
  # shellcheck disable=SC2086  # "<partition> <path>"
  p=$(get $f); [ -z "$p" ] || args+=("$p")
done
"$B/secilc" "${args[@]}" -o "$X/policy" -f /dev/null > "$X/log" 2>&1 ||
  { cat "$X/log" >&2; echo "check-sepolicy: the SELinux policy doesn't compile: init would fail at boot" >&2; exit 1; }
echo "   SELinux policy compiles ($(( $(stat -c %s "$X/policy") / 1024 )) KiB, as init builds it at boot)"
