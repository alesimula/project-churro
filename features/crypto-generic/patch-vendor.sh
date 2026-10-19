#!/usr/bin/env bash
# Replace the partition's BoringSSL (libcrypto.so + libssl.so) with our build of the same source
# for any Haswell-or-newer CPU (crypto/build-boringssl.sh): Google's -march=pantherlake build
# uses SHA-NI/VAES/VPCLMULQDQ/ADX without asking the CPU, which the kernel emulator then has to
# trap on older machines (keystore, TLS). Ours checks CPUID like upstream does, so new CPUs keep
# every fast path. The build stops unless its exports match the image's exactly.
# Used for vendor and (patch-system.sh) system. Written in place: labels are kept.
set -euo pipefail
D=$1/${CHURRO_CRYPTO_SUB:-}lib64 O=${CHURRO_CACHE:-/var/cache/churro}/boringssl
bash "$CHURRO_HERE/crypto/build-boringssl.sh" "$O" "$D"
for so in libcrypto.so libssl.so; do cat "$O/out/$so" > "$D/$so"; done
echo "   ${CHURRO_CRYPTO_SUB:-vendor/}lib64: BoringSSL rebuilt for x86-64-v3 (CPUID dispatch)"
