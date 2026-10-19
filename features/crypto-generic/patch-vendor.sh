#!/usr/bin/env bash
# Replace the partition's BoringSSL (libcrypto.so + libssl.so) with our build of the same source
# for any Haswell-or-newer CPU (crypto/build-boringssl.sh): Google's -march=pantherlake build
# uses SHA-NI/VAES/VPCLMULQDQ/ADX without asking the CPU, which the kernel emulator then has to
# trap on older machines (keystore, TLS). Ours checks CPUID like upstream does, so new CPUs keep
# every fast path. The build stops unless it exports everything the image's libraries export.
# Used for vendor and (patch-system.sh) system. Written in place: labels are kept.
set -euo pipefail
D=$1/${CHURRO_CRYPTO_SUB:-}lib64 O=${CHURRO_CACHE:-/var/cache/churro}/boringssl
bash "$CHURRO_HERE/crypto/build-boringssl.sh" "$O" "$D"
for so in libcrypto.so libssl.so; do cat "$O/out/$so" > "$D/$so"; done
echo "   ${CHURRO_CRYPTO_SUB:-vendor/}lib64: BoringSSL rebuilt for x86-64-v3 (CPUID dispatch)"
[ -z "${CHURRO_CRYPTO_SUB:-}" ] || exit 0
# vendor only: let init bind-mount over the APEXes' copies (system/etc/init/churro-apex-crypto.rc);
# their files are labelled system_lib_file, system_file or vendor_file. SELinux stays enforcing:
# init (already root, loads the policy) gains only "mount over a file" on these three types.
# Policy compiled on-device (precompiled one removed, as debug-log does).
S=$1/etc/selinux V=$(cat "$1/etc/selinux/plat_sepolicy_vers.txt")
cat >> "$S/vendor_sepolicy.cil" <<EOF
; Project Churro crypto-generic: init bind-mounts our BoringSSL over the APEX copies
(allow init_$V system_lib_file_$V (file (mounton)))
(allow init_$V system_file_$V (file (mounton)))
(allow init_$V vendor_file_$V (file (mounton)))
EOF
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256
echo "   vendor: SELinux: init may bind-mount over the APEX BoringSSL copies"
