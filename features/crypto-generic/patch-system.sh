#!/usr/bin/env bash
# system is mounted at /: its libraries are under system/lib64 (see patch-vendor.sh)
set -euo pipefail
CHURRO_CRYPTO_SUB=system/ bash "$(dirname "$0")/patch-vendor.sh" "$@"

# HttpEngine's own BoringSSL (Tethering APEX): rebuilt from the image's copy and installed as
# /system/lib64/libcrypto_httpengine.so, which churro-apex-crypto.rc bind-mounts over the APEX's.
A=$1/system/apex/com.google.android.tethering.apex O=${CHURRO_CACHE:-/var/cache/churro}/boringssl
X=$(mktemp -d); trap 'rm -rf "$X"' EXIT
unzip -p "$A" apex_payload.img > "$X/p.img"
"${EROFS_BIN:?}/fsck.erofs" --extract="$X/x" "$X/p.img" >/dev/null 2>&1 && cp "$X/x/lib64/libcrypto_httpengine.so" "$X/image.so" ||
  debugfs -R "dump /lib64/libcrypto_httpengine.so $X/image.so" "$X/p.img" >/dev/null 2>&1 || true   # payload: EROFS, or ext4
[ -s "$X/image.so" ] || { echo "no libcrypto_httpengine.so in $A" >&2; exit 1; }
bash "$CHURRO_HERE/crypto/build-boringssl-httpengine.sh" "$O" "$X/image.so"
D=$1/system/lib64/libcrypto_httpengine.so
install -m 0644 -o root -g root "$O/out-httpengine/libcrypto_httpengine.so" "$D"
setfattr -n security.selinux -v "$(getfattr --only-values -n security.selinux "$1/system/lib64/libcrypto.so")" "$D"
echo "   system/lib64: libcrypto_httpengine.so (HttpEngine's BoringSSL) rebuilt for x86-64-v3"
