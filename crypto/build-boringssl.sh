#!/usr/bin/env bash
# Rebuild the image's BoringSSL (libcrypto.so + libssl.so) for any Haswell-or-newer x86-64 CPU.
# Google built the Googlebook image with -march=pantherlake, which turns BoringSSL's CPUID
# checks (CRYPTO_is_*_capable(), crypto/internal.h) into compile-time "yes": SHA-NI, VAES,
# VPCLMULQDQ, ADX, ... are then used unconditionally and trap into the kernel emulator on older
# CPUs. This is the same source (upstream BoringSSL, which AOSP's external/boringssl imports
# unchanged), with Android's own build options (FIPS shared module + integrity hash,
# OPENSSL_SMALL, BORINGSSL_ANDROID_SYSTEM, static and hidden libc++, -Bsymbolic), but
# -march=x86-64-v3: the CPUID checks are real again, so new CPUs keep every fast path and old
# ones take the code they can run.
# Version: BORINGSSL_REV in versions.env (how it was found: there). The image's BoringSSL is
# newer than AOSP's android17-release (upstream d32c35e5, Jan 2026).
# ABI gate: the result must export every dynamic symbol the image's library exports (same name,
# type, binding and data object size), else the build stops; extra exports (a newer REV) are
# allowed and counted. A new recovery image: the gate tells whether REV still fits.
# Usage: crypto/build-boringssl.sh <work dir> <image lib64 dir>   -> <work dir>/out/lib{crypto,ssl}.so
set -euo pipefail
W=$(mkdir -p "$1" && cd "$1" && pwd) IMG=$2
. "$(dirname "$0")/../versions.env"
NDK=${CHURRO_NDK:-${CHURRO_MESA:?}/../android-ndk-$NDK_VER}
REV=$BORINGSSL_REV GOV=$BORINGSSL_GO_VER GOSHA=$BORINGSSL_GO_SHA256
ARCH=x86-64-v3                                    # Haswell+ / Zen: the rest of the image's floor

dl() {  # <url> <dest file>
  local i; for i in 1 2 3; do curl -fsSL -o "$2.tmp" "$1" && { mv "$2.tmp" "$2"; return 0; }; sleep 5; done
  echo "download failed: $1" >&2; exit 1
}
if [ ! -d "$W/src-$REV" ]; then
  dl "https://boringssl.googlesource.com/boringssl/+archive/$REV.tar.gz" "$W/bssl.tgz"
  rm -rf "$W/src.tmp"; mkdir -p "$W/src.tmp"; tar -xzmf "$W/bssl.tgz" -C "$W/src.tmp"; rm "$W/bssl.tgz"
  mv "$W/src.tmp" "$W/src-$REV"
fi
if [ ! -x "$W/go-$GOV/bin/go" ]; then
  dl "https://go.dev/dl/go$GOV.linux-amd64.tar.gz" "$W/go.tgz"
  echo "$GOSHA  $W/go.tgz" | sha256sum -c --quiet
  rm -rf "$W/go.tmp"; mkdir -p "$W/go.tmp"; tar -xzf "$W/go.tgz" -C "$W/go.tmp"; rm "$W/go.tgz"
  mv "$W/go.tmp/go" "$W/go-$GOV"; rmdir "$W/go.tmp"
fi
# Go only runs the FIPS hash injector (util/fipstools/inject_hash): local packages, no network
export GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=mod GOCACHE=$W/gocache GOPATH=$W/gopath

# inside the source tree: the hash injector runs `go run` from here and must find BoringSSL's go.mod
B=$W/src-$REV/build-churro; rm -rf "$B" "$W/out"; mkdir -p "$W/out"
# libcrypto exports two internal C++ helpers taking std::atomic (bssl::CRYPTO_refcount_*), used
# by libssl: Google built with the platform libc++ (namespace std::__1), the NDK's headers say
# std::__ndk1. Same headers, platform ABI namespace; libc++ templates are instantiated locally
# (_LIBCPP_DISABLE_EXTERN_TEMPLATE) instead of taken from the NDK's static libc++ (std::__ndk1).
# std::sort's core (__sort) lives only in the libc++ library: the one libssl uses (unsigned
# short, signature-algorithm lists of a few entries) is defined here (insertion sort; no libc++
# header, which would already instantiate it) in a small archive that --exclude-libs keeps
# hidden like the rest of libc++.
mkdir -p "$W/cxx"
T=$NDK/toolchains/llvm/prebuilt/linux-x86_64
sed 's/_LIBCPP_ABI_NAMESPACE __ndk1/_LIBCPP_ABI_NAMESPACE __1/' \
  "$T/sysroot/usr/include/c++/v1/__config_site" > "$W/cxx/__config_site"
FL="-march=$ARCH -DBORINGSSL_ANDROID_SYSTEM"
cat > "$W/cxx/sort.cc" <<'EOF'
namespace std { inline namespace __1 {
template <class T1 = void, class T2 = T1> struct __less;
template <class C, class I> void __sort(I, I, C);
template <> void __sort<__less<unsigned short>&, unsigned short*>(unsigned short* f, unsigned short* l, __less<unsigned short>&) {
  for (unsigned short* i = f + (f != l); i < l; i++)
    for (unsigned short* j = i, v = *i; ; j--) { if (j == f || j[-1] <= v) { *j = v; break; } *j = j[-1]; }
}
}}
EOF
"$T/bin/clang++" --target=x86_64-linux-android29 $FL -O2 -fPIC -c "$W/cxx/sort.cc" -o "$W/cxx/sort.o"
"$T/bin/llvm-ar" rcs "$W/cxx/libsort.a" "$W/cxx/sort.o"
cmake -S "$W/src-$REV" -B "$B" -G Ninja -Wno-dev \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-29 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=1 -DFIPS=1 -DOPENSSL_SMALL=1 -DBUILD_TESTING=OFF \
  -DGO_EXECUTABLE="$W/go-$GOV/bin/go" -DCMAKE_C_FLAGS="$FL" -DCMAKE_CXX_FLAGS="$FL -isystem $W/cxx -D_LIBCPP_DISABLE_EXTERN_TEMPLATE" \
  -DCMAKE_CXX_STANDARD_LIBRARIES="$W/cxx/libsort.a" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-Bsymbolic -Wl,--exclude-libs,ALL" >"$W/cmake.log" 2>&1 || { tail -30 "$W/cmake.log" >&2; exit 1; }
ninja -C "$B" crypto ssl >"$W/ninja.log" 2>&1 || { tail -30 "$W/ninja.log" >&2; exit 1; }

# strip like the image (non-allocated sections only: the FIPS hash covers .text/.rodata, unchanged)
for l in crypto ssl; do
  "$T/bin/llvm-strip" --strip-unneeded -o "$W/out/lib$l.so" "$B/lib$l.so"
done

# --- ABI gate: every dynamic symbol the image's libraries export, ours export too ---
syms() { readelf --dyn-syms -W "$1" | awk '$7 != "UND" && $5 != "LOCAL" && NF >= 8 {
  sub(/@.*/, "", $8); if ($8 != "__llvm_fs_discriminator__") print $8, $4, $5, ($4 == "OBJECT" ? $3 : "")}' | LC_ALL=C sort -u; }
# (__llvm_fs_discriminator__: a marker of Google's AutoFDO build, imported by nothing)
bad=0 info=""
for l in crypto ssl; do
  syms "$IMG/lib$l.so" > "$W/abi-$l.image"; syms "$W/out/lib$l.so" > "$W/abi-$l.ours"
  LC_ALL=C comm -23 "$W/abi-$l.image" "$W/abi-$l.ours" > "$W/abi-$l.missing"
  extra=$(LC_ALL=C comm -13 "$W/abi-$l.image" "$W/abi-$l.ours" | wc -l)
  if [ -s "$W/abi-$l.missing" ]; then
    echo "lib$l.so: $(wc -l < "$W/abi-$l.missing") of the image's exports missing or different ($W/abi-$l.missing)" >&2; bad=1
  fi
  info="$info lib$l $(wc -l < "$W/abi-$l.image") exports present, $extra extra;"
done
[ "$bad" = 0 ] || exit 1
grep -q BORINGSSL_integrity_test <(readelf --dyn-syms -W "$W/out/libcrypto.so") || { echo "libcrypto.so: not a FIPS build" >&2; exit 1; }
echo "   BoringSSL $REV (-march=$ARCH, FIPS): libcrypto $(stat -c %s "$W/out/libcrypto.so") B, libssl $(stat -c %s "$W/out/libssl.so") B;$info"
