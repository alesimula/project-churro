#!/usr/bin/env bash
# Googlebook setup makes Google's OTA mandatory when checkin says so (gservices update_url +
# update_required_setup). Our partitions differ, so it can never install (update_engine is gone,
# firmware-lockdown) and setup stops at "Something went wrong" with no way forward.
# A static overlay on the setup app's flow scripts (plain-text raw resources) changes only the
# "ota_available" result from ota_update to early_update - what Google's own QR/NFC provisioning
# flows already do. Built from this image's own scripts, so it follows the release. If the step
# isn't found, nothing is added (setup then asks for the OTA again).
# Usage: patch-system_ext.sh <extracted system_ext tree>
set -euo pipefail
S=$1 H=$(dirname "$0")/../..
A=$(find "$S/priv-app" -name 'SetupWizardDesktop*.apk' -print -quit 2>/dev/null)
[ -n "$A" ] || { echo "   system_ext: no desktop SetupWizard (nothing to do)"; exit 0; }
. "$H/versions.env"; . "$H/lib/emu-image.sh"

# Google's build-tools (aapt2, zipalign, apksigner), downloaded once
C=${CHURRO_CACHE:-/var/cache/churro}; Z=$C/$(basename "$CHURRO_BUILDTOOLS_URL"); B=$C/${Z##*/}.d
if [ ! -f "$B/.done" ]; then
  echo "$CHURRO_BUILDTOOLS_SHA1  $Z" | sha1sum -c --quiet >/dev/null 2>&1 || curl -fsSL -o "$Z" "$CHURRO_BUILDTOOLS_URL"
  echo "$CHURRO_BUILDTOOLS_SHA1  $Z" | sha1sum -c --quiet
  rm -rf "$B"; mkdir -p "$B"; unzip -q "$Z" -d "$B"; touch "$B/.done"
fi
B=$(dirname "$(find "$B" -name aapt2 -print -quit)")

[ -z "$("$B/aapt2" dump overlayable "$A")" ] || { echo "   system_ext: setup app limits overlays (nothing to do)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/res/raw"
# raw/wizard_script* resource -> its (obfuscated) file in the APK
"$B/aapt2" dump resources "$A" | awk '/^ *resource 0x[0-9a-f]+ raw\/wizard_script/ { n = $3; sub(/^raw\//, "", n); getline; print n, $NF }' |
while read -r n f; do
  unzip -p "$A" "$f" > "$W/in"
  grep -q 'id="early_update"' "$W/in" || continue
  sed -zE 's/(<result[^>]*wizard:name="ota_available"[^>]*wizard:action=")ota_update"/\1early_update"/g' "$W/in" > "$W/out"
  cmp -s "$W/in" "$W/out" || { mv "$W/out" "$W/res/raw/$n.xml"; echo "   system_ext: setup flow $n: required OTA -> early_update"; }
done
ls "$W"/res/raw/*.xml >/dev/null 2>&1 || { echo "   system_ext: no required-OTA step in the setup flow (nothing to do)"; exit 0; }

pkg=$("$B/aapt2" dump packagename "$A")
sdk=$(sed -n 's/^ro\.system_ext\.build\.version\.sdk=//p' "$S/etc/build.prop")
cat > "$W/AndroidManifest.xml" <<M
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.churro.overlay.setupnoota">
  <uses-sdk android:minSdkVersion="$sdk" android:targetSdkVersion="$sdk"/>
  <application android:hasCode="false"/>
  <overlay android:targetPackage="$pkg" android:isStatic="true" android:priority="0"/>
</manifest>
M
FW=$(emu_part system)/system/framework/framework-res.apk   # android: attributes
"$B/aapt2" compile --dir "$W/res" -o "$W/res.zip"
"$B/aapt2" link -o "$W/u.apk" -I "$FW" --manifest "$W/AndroidManifest.xml" "$W/res.zip"
"$B/zipalign" -p -f 4 "$W/u.apk" "$W/a.apk"
# throwaway key: a preinstalled overlay needs a valid signature, not a particular key. Android
# doesn't check certificate dates on APKs; the 1000 years are cosmetic.
keytool -genkeypair -keystore "$W/k" -storepass churro -alias o -keyalg RSA -keysize 2048 \
  -validity 365000 -dname CN=Churro >/dev/null 2>&1
O=$S/overlay/ChurroSetupNoOta.apk
"$B/apksigner" sign --ks "$W/k" --ks-pass pass:churro --out "$O" "$W/a.apk"
chmod 0644 "$O"; rm -f "$O.idsig"
l=$(getfattr --only-values -n security.selinux "$S/overlay" 2>/dev/null | tr -d '\0') || true
[ -z "$l" ] || setfattr -n security.selinux -v "$l" "$O"   # same label as the overlay dir (vendor_overlay_file)
# A partition with overlay/config/config.xml enables only the overlays listed there (isStatic is
# then ignored and an unlisted overlay stays disabled): add ours, enabled. Not mutable="false":
# immutable entries must come before mutable ones, else zygote throws and nothing boots.
X=$S/overlay/config/config.xml
if [ -f "$X" ]; then
  c=$(sed 's|</config>|  <overlay package="org.churro.overlay.setupnoota" enabled="true" />\n</config>|' "$X")
  printf '%s\n' "$c" > "$X"   # in place: keeps the SELinux label
  grep -q 'org.churro.overlay.setupnoota' "$X" || { echo "overlay not added to $X" >&2; exit 1; }
fi
echo "   system_ext: overlay/${O##*/} -> $pkg"
