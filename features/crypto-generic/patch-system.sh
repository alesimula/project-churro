#!/usr/bin/env bash
# system is mounted at /: its libraries are under system/lib64 (see patch-vendor.sh)
set -euo pipefail
. "$(dirname "$0")/../../lib/note.sh"
CHURRO_CRYPTO_SUB=system/ bash "$(dirname "$0")/patch-vendor.sh" "$@"

# HttpEngine's own BoringSSL (Tethering APEX): rebuilt from the image's copy and installed as
# /system/lib64/libcrypto_httpengine.so, which churro-apex-crypto.rc bind-mounts over the APEX's.
A=$1/system/apex/com.google.android.tethering.apex O=${CHURRO_CACHE:-/var/cache/churro}/boringssl
X=$(mktemp -d); trap 'rm -rf "$X"' EXIT
unzip -p "$A" apex_payload.img > "$X/p.img"
"${EROFS_BIN:?}/fsck.erofs" --extract="$X/x" "$X/p.img" >/dev/null 2>&1 && cp "$X/x/lib64/libcrypto_httpengine.so" "$X/image.so" ||
  debugfs -R "dump /lib64/libcrypto_httpengine.so $X/image.so" "$X/p.img" >/dev/null 2>&1 || true   # payload: EROFS, or ext4
[ -s "$X/image.so" ] || { echo "no libcrypto_httpengine.so in $A" >&2; exit 1; }
# The pin is the commit Chromium used for one HttpEngine version: the export check below can pass
# for another version's library too, so compare the version the image's libhttpengine.so states.
. "$CHURRO_HERE/versions.env"
HE=$X/x/lib64/libhttpengine.so
[ -s "$HE" ] || { HE=$X/he.so; debugfs -R "dump /lib64/libhttpengine.so $HE" "$X/p.img" >/dev/null 2>&1 || true; }
hv=$(strings -a "$HE" 2>/dev/null | grep -m1 -xE '[0-9]{2,3}\.0\.[0-9]{4}\.[0-9]{1,3}' || true)
[ "$hv" = "$BORINGSSL_HTTPENGINE_FOR" ] ||
  note "crypto-generic: the image's HttpEngine is Chromium ${hv:-(version not found)}, BORINGSSL_HTTPENGINE_REV was chosen for $BORINGSSL_HTTPENGINE_FOR: take the BoringSSL commit that Chromium version's DEPS pins (versions/api$CHURRO_API.env)"
bash "$CHURRO_HERE/crypto/build-boringssl-httpengine.sh" "$O" "$X/image.so"
D=$1/system/lib64/libcrypto_httpengine.so
install -m 0644 -o root -g root "$O/out-httpengine/libcrypto_httpengine.so" "$D"
setfattr -n security.selinux -v "$(getfattr --only-values -n security.selinux "$1/system/lib64/libcrypto.so")" "$D"
echo "   system/lib64: libcrypto_httpengine.so (HttpEngine's BoringSSL) rebuilt for x86-64-v3"
