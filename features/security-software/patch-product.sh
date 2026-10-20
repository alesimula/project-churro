#!/usr/bin/env bash
# Googlebooks are "RKP-only": attestation keys come only from Google's provisioning server, which
# serves registered Google hardware. Our software KeyMint gets "444 Device not registered", so
# every attested key generation failed (Play Integrity tokens, apps' key attestation).
# rkp_only=0 (as on the emulator): keystore falls back to KeyMint's own attestation key.
# No hostname: RKPD reports "RKP is disabled" at once, instead of keystore waiting 10 s for a
# server round trip that can only fail (every attested key took 10 s, apps timed out).
# Usage: patch-product.sh <extracted product tree>
set -euo pipefail
P=$1/etc/build.prop
grep -q '^remote_provisioning\.' "$P" || { echo "   product: no remote_provisioning props (nothing to do)"; exit 0; }
c=$(sed -E 's/^(remote_provisioning\.(tee|strongbox)\.rkp_only)=.*/\1=0/; /^remote_provisioning\.hostname=/d' "$P")
printf '%s\n' "$c" > "$P"   # in place: keeps the SELinux label
! grep -qE 'rkp_only=1|^remote_provisioning\.hostname=' "$P" || { echo "RKP still enabled in $P" >&2; exit 1; }
echo "   product: RKP off (rkp_only=0, no hostname): software KeyMint attests with its own key"
