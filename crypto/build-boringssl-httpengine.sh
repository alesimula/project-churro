#!/usr/bin/env bash
# Rebuild libcrypto_httpengine.so (Tethering APEX): the BoringSSL of HttpEngine, the platform's
# Cronet (libhttpengine.so, preloaded by zygote, so in every app process). Like the platform copy
# (build-boringssl.sh), Google built it with -march=pantherlake, so its AES-GCM/SHA/... CPUID
# checks are compile-time "yes" and older CPUs trap on every TLS record. Same source, -march=x86-64-v3.
# How AOSP builds it: libcrypto as a plain static library (default visibility), linked into a
# shared object that exports exactly what libhttpengine.so imports, under the version name
# INTERSECTED_SYMBOLS. That set includes internal C++ helpers taking std::atomic, compiled with
# Chromium's libc++ (namespace std::__Cr): we compile in that namespace, libc++ itself stays
# static and local. Not a FIPS module (no integrity hash), no libssl (libhttpengine embeds its own).
# Version: BORINGSSL_HTTPENGINE_REV in versions.env (must match the image's Chromium exactly).
# Gate: the result exports exactly the image's symbols (name, type, binding, data size) under the
# same version name; the link fails if any of them is missing.
# Usage: crypto/build-boringssl-httpengine.sh <work dir> <image's libcrypto_httpengine.so>
#        -> <work dir>/out-httpengine/libcrypto_httpengine.so
set -euo pipefail
W=$(mkdir -p "$1" && cd "$1" && pwd) IMGLIB=$2
. "$(dirname "$0")/../versions.env"
NDK=${CHURRO_NDK:-${CHURRO_MESA:?}/../android-ndk-$NDK_VER}
REV=$BORINGSSL_HTTPENGINE_REV ARCH=x86-64-v3
T=$NDK/toolchains/llvm/prebuilt/linux-x86_64
if [ ! -d "$W/src-$REV" ]; then
  for i in 1 2 3; do curl -fsSL -o "$W/bssl.tgz" "https://boringssl.googlesource.com/boringssl/+archive/$REV.tar.gz" && break
    [ $i = 3 ] && { echo "download failed: BoringSSL $REV" >&2; exit 1; }; sleep 5; done
  rm -rf "$W/src.tmp"; mkdir -p "$W/src.tmp"; tar -xzmf "$W/bssl.tgz" -C "$W/src.tmp"; rm "$W/bssl.tgz"
  mv "$W/src.tmp" "$W/src-$REV"
fi
B=$W/src-$REV/build-httpengine O=$W/out-httpengine; rm -rf "$B" "$O"; mkdir -p "$O" "$W/cxx-cr"
sed 's/_LIBCPP_ABI_NAMESPACE __ndk1/_LIBCPP_ABI_NAMESPACE __Cr/' \
  "$T/sysroot/usr/include/c++/v1/__config_site" > "$W/cxx-cr/__config_site"
FL="-march=$ARCH"
# BoringSSL's CMake adds -fvisibility=hidden to CMAKE_C_FLAGS; the *_RELEASE flags come after it
cmake -S "$W/src-$REV" -B "$B" -G Ninja -Wno-dev \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-29 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=0 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DOPENSSL_SMALL=1 -DBUILD_TESTING=OFF \
  -DCMAKE_C_FLAGS="$FL" -DCMAKE_CXX_FLAGS="$FL -isystem $W/cxx-cr -D_LIBCPP_DISABLE_EXTERN_TEMPLATE" \
  -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG -fvisibility=default" \
  -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG -fvisibility=default" >"$W/cmake-httpengine.log" 2>&1 ||
  { tail -30 "$W/cmake-httpengine.log" >&2; exit 1; }
ninja -C "$B" crypto >"$W/ninja-httpengine.log" 2>&1 || { tail -30 "$W/ninja-httpengine.log" >&2; exit 1; }

syms() { readelf --dyn-syms -W "$1" | awk '$1 ~ /^[0-9]+:$/ && $7 != "UND" && $5 != "LOCAL" && NF >= 8 {
  v = $8; sub(/^[^@]*/, "", v); sub(/@.*/, "", $8); print $8, $4, $5, ($4 == "OBJECT" ? $3 : ""), v}' | LC_ALL=C sort -u; }
syms "$IMGLIB" > "$O/abi.image"
ver=$(awk '{print $NF}' "$O/abi.image" | sort -u)
[ "$ver" = "@@INTERSECTED_SYMBOLS" ] || { echo "unexpected symbol versions in $IMGLIB: $ver" >&2; exit 1; }
# libc++'s one non-inline helper the headers reference (assert/throw paths), in the __Cr
# namespace the NDK's static libc++ doesn't have: abort, like Chromium's hardened libc++.
printf '%s\n' 'extern "C" [[noreturn]] void abort();' \
  'namespace std { inline namespace __Cr { [[noreturn]] void __libcpp_verbose_abort(const char*, ...) { abort(); } } }' > "$O/abort.cc"
"$T/bin/clang++" --target=x86_64-linux-android29 $FL -O2 -fPIC -c "$O/abort.cc" -o "$O/abort.o"
{ echo "INTERSECTED_SYMBOLS {"; echo "  global:"; awk '{print "    " $1 ";"}' "$O/abi.image"; echo "  local: *;"; echo "};"; } > "$O/exports.map"
"$T/bin/clang++" --target=x86_64-linux-android29 -shared -o "$O/libcrypto_httpengine.unstripped.so" \
  -Wl,-soname,libcrypto_httpengine.so -Wl,--whole-archive "$B/libcrypto.a" -Wl,--no-whole-archive "$O/abort.o" \
  -static-libstdc++ -Wl,--version-script="$O/exports.map" -Wl,--no-undefined -Wl,--no-undefined-version \
  -Wl,-Bsymbolic -Wl,-z,now -Wl,--build-id=sha1 >"$O/link.log" 2>&1 || { head -30 "$O/link.log" >&2; exit 1; }
"$T/bin/llvm-strip" --strip-unneeded -o "$O/libcrypto_httpengine.so" "$O/libcrypto_httpengine.unstripped.so"
syms "$O/libcrypto_httpengine.so" > "$O/abi.ours"
diff "$O/abi.image" "$O/abi.ours" > "$O/abi.diff" ||
  { echo "libcrypto_httpengine.so: exports differ from the image's ($(grep -c '^[<>]' "$O/abi.diff") lines, $O/abi.diff)" >&2; exit 1; }
echo "   BoringSSL $REV for HttpEngine (-march=$ARCH): $(stat -c %s "$O/libcrypto_httpengine.so") B; $(wc -l < "$O/abi.image") exports identical to the image's"
