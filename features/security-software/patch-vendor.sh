#!/usr/bin/env bash
# "software security" vendor side:
#  1. drop HALs that only work on top of Trusty / the GSC (and their VINTF fragments),
#  2. install AOSP's software KeyMint (android.hardware.security.keymint-service, the one the
#     Android emulator uses) taken from Google's public Android 17 emulator system image.
#     Same binary name as AOSP's default -> Googlebook's sepolicy already labels it
#     hal_keymint_default_exec, so no policy changes are needed.
# Usage: patch-vendor.sh <extracted vendor tree>
set -euo pipefail
V=$1
CACHE=${CHURRO_CACHE:-/var/cache/churro}
EMU_URL=${CHURRO_EMU_URL:-https://dl.google.com/android/repository/sys-img/google_apis/x86_64-37.0_r06.zip}
EMU_SHA1=${CHURRO_EMU_SHA1:-629e507fd5b737c2c836b12b52c81cd0e3b12399}

for n in android.hardware.gatekeeper-service.trusty android.hardware.security.secretkeeper.trusty \
         android.hardware.security.secretkeeper.trusty.desktop android.hardware.weaver-service.android-desktop \
         vendor.google.desktop.oemlock-service; do
  rm -f "$V/etc/init/$n.rc" "$V/etc/vintf/manifest/$n.xml"
done
# Also Google-hardware-only services that just fail and restart all session: the Pixel face HAL
# (talks to a Trusty TA, SIGSEGVs), the EC charge-control HAL (exits at once, init restarts it
# every 5 s).
rm -f "$V/apex/com.google.android.hardware.biometrics.face.apex" \
      "$V/etc/init/hal_desktop_charge_control_default.rc" \
      "$V/etc/vintf/manifest/com.android.desktop.power.charge_control.xml"
echo "   vendor: Trusty/GSC HALs, face HAL, EC charge control removed"

# --- fetch + unpack the emulator vendor partition once (cached) ---
E=$CACHE/emu-vendor
if [ ! -f "$E/.done" ]; then
  mkdir -p "$CACHE"; Z=$CACHE/$(basename "$EMU_URL")
  [ -f "$Z" ] && echo "$EMU_SHA1  $Z" | sha1sum -c --quiet 2>/dev/null || { echo "   downloading $(basename "$Z") (~2.2 GB, once)"; curl -fL# -o "$Z" "$EMU_URL"; }
  echo "$EMU_SHA1  $Z" | sha1sum -c --quiet
  T=$(mktemp -d); unzip -q -o "$Z" '*/vendor.img' -d "$T"
  L=$(losetup -f --show -r -P "$(find "$T" -name vendor.img)"); sleep 1
  rm -rf "$E"; mkdir -p "$E"; debugfs -R "rdump / $E" "${L}p1" >/dev/null 2>&1; losetup -d "$L"; rm -rf "$T"
  touch "$E/.done"
fi

# --- install KeyMint + its missing libraries (dependency closure) ---
lbl() { setfattr -n security.selinux -v "$2" "$1"; }
install -m 0755 -o root -g 2000 "$E/bin/hw/android.hardware.security.keymint-service" "$V/bin/hw/"
lbl "$V/bin/hw/android.hardware.security.keymint-service" u:object_r:hal_keymint_default_exec:s0
install -m 0644 "$E/etc/init/android.hardware.security.keymint-service.rc" "$V/etc/init/"
lbl "$V/etc/init/android.hardware.security.keymint-service.rc" u:object_r:vendor_configs_file:s0
for x in "$E"/etc/vintf/manifest/*.xml; do
  grep -qE 'security\.(keymint|sharedsecret|secureclock)' "$x" || continue
  install -m 0644 "$x" "$V/etc/vintf/manifest/"; lbl "$V/etc/vintf/manifest/$(basename "$x")" u:object_r:vendor_configs_file:s0
done
libl=$(getfattr --only-values -n security.selinux "$V/lib64/libbase.so" 2>/dev/null || echo u:object_r:vendor_file:s0)
todo=("$E/bin/hw/android.hardware.security.keymint-service"); added=""
while [ ${#todo[@]} -gt 0 ]; do
  f=${todo[0]}; todo=("${todo[@]:1}")
  for n in $(readelf -d "$f" | awk '/NEEDED/ {gsub(/[][]/, "", $NF); print $NF}'); do
    [ -e "$V/lib64/$n" ] && continue
    [ -e "$E/lib64/$n" ] || continue          # LL-NDK / system lib, provided by the platform
    install -m 0644 "$E/lib64/$n" "$V/lib64/"; lbl "$V/lib64/$n" "$libl"
    added="$added $n"; todo+=("$E/lib64/$n")
  done
done
echo "   vendor: software KeyMint installed (+libs:$added)"

# --- software Gatekeeper (lock-screen PIN/password) ---
# The Trusty gatekeeper is gone above; without any Gatekeeper HAL gatekeeperd can't enroll and
# setting a lock-screen credential fails (IGateKeeperService.clearSecureUserId:
# IllegalStateException). Install AOSP's non-secure Gatekeeper from the emulator's
# com.android.hardware.gatekeeper.nonsecure APEX as /vendor/bin/hw/android.hardware.gatekeeper-service,
# which the image's file_contexts already label hal_gatekeeper_default_exec (AOSP's default
# gatekeeper domain, allowed to register IGatekeeper/default + ISharedSecret/gatekeeper).
G=$CACHE/emu-gatekeeper
if [ ! -f "$G/.done" ]; then
  rm -rf "$G"; mkdir -p "$G/x"
  unzip -p "$E/apex/com.android.hardware.gatekeeper.nonsecure.apex" apex_payload.img > "$G/p.img"
  debugfs -R "rdump / $G/x" "$G/p.img" >/dev/null 2>&1; rm -f "$G/p.img"
  [ -x "$G/x/bin/hw/android.hardware.gatekeeper-service.nonsecure" ] || { echo "gatekeeper not found in the emulator APEX" >&2; exit 1; }
  touch "$G/.done"
fi
gk=$V/bin/hw/android.hardware.gatekeeper-service
install -m 0755 -o root -g 2000 "$G/x/bin/hw/android.hardware.gatekeeper-service.nonsecure" "$gk"
lbl "$gk" u:object_r:hal_gatekeeper_default_exec:s0
printf '%s\n' 'service vendor.gatekeeper-default /vendor/bin/hw/android.hardware.gatekeeper-service' \
  '    class early_hal' '    user system' '    group system' > "$V/etc/init/android.hardware.gatekeeper-service.rc"
lbl "$V/etc/init/android.hardware.gatekeeper-service.rc" u:object_r:vendor_configs_file:s0
for x in "$G"/x/etc/vintf/*.xml; do
  install -m 0644 "$x" "$V/etc/vintf/manifest/"; lbl "$V/etc/vintf/manifest/$(basename "$x")" u:object_r:vendor_configs_file:s0
done
todo=("$gk"); added=""
while [ ${#todo[@]} -gt 0 ]; do
  f=${todo[0]}; todo=("${todo[@]:1}")
  for n in $(readelf -d "$f" | awk '/NEEDED/ {gsub(/[][]/, "", $NF); print $NF}'); do
    [ -e "$V/lib64/$n" ] && continue
    s=$G/x/lib64/$n; [ -e "$s" ] || s=$E/lib64/$n; [ -e "$s" ] || continue
    install -m 0644 "$s" "$V/lib64/"; lbl "$V/lib64/$n" "$libl"
    added="$added $n"; todo+=("$s")
  done
done
echo "   vendor: software Gatekeeper installed (+libs:${added:- none})"
