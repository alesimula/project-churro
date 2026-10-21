#!/usr/bin/env bash
# Build Mesa for Android x86_64 with the NDK (no AOSP tree needed: -Dandroid-stub=true).
# Gives Churro GPU support the Googlebook vendor image lacks:
#   GL/GLES (ro.hardware.egl=mesa): iris (Intel Gen8+, e.g. Broadwell HD 5300), crocus (Gen4-7),
#     nouveau (NVIDIA up to Ada), zink (GL on Vulkan: NVIDIA Kepler+ on NVK), virgl (QEMU
#     virtio-gpu-gl), softpipe (software, any GPU)
#   Vulkan (ro.hardware.vulkan=...): nouveau (NVK, NVIDIA Kepler+), intel_hasvk (Gen7/8), radeon (AMD)
# NVK is partly Rust: rustc/cargo (with the x86_64-linux-android std, built panic=abort like all
# Android Rust) and bindgen are the GKI kernel build's toolchain (prepare.sh passes them);
# cbindgen is built once with that cargo.
# Usage: CHURRO_RUST=<rust dir> CHURRO_BINDGEN=<dir with bindgen> CHURRO_CLANG=<its clang dir> \
#          gfx/build-mesa.sh <work dir>      -> <work dir>/install/... (meson DESTDIR)
set -euo pipefail
WORK=$1
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../versions.env"   # MESA_VER, NDK_VER, LIBDRM_VER
API=${ANDROID_API:-35}
RUST=${CHURRO_RUST:?} BINDGEN=${CHURRO_BINDGEN:?}
# bindgen: libclang and the clang it asks for include dirs must be the same version
export LIBCLANG_PATH=${CHURRO_CLANG:?}/lib CLANG_PATH=$CHURRO_CLANG/bin/clang
mkdir -p "$WORK"; cd "$WORK"
# Mesa 26 needs meson >= 1.4 (Ubuntu 24.04 ships 1.3): private venv with the python bits
[ -x venv/bin/meson ] || { python3 -m venv venv && venv/bin/pip -q install 'meson>=1.4' mako pyyaml ply packaging; }
export CARGO_HOME=$WORK/cargo
export PATH=$WORK/venv/bin:$RUST/bin:$BINDGEN:$CARGO_HOME/bin:$PATH
[ -x "$CARGO_HOME/bin/cbindgen" ] || cargo install -q --locked --version 0.29.0 cbindgen
[ -d "android-ndk-$NDK_VER" ] || { curl -fsSL -o ndk.zip "https://dl.google.com/android/repository/android-ndk-$NDK_VER-linux.zip"; unzip -q ndk.zip; rm ndk.zip; }
# fresh source + gfx/mesa-patches/ on every build
[ -f "mesa-$MESA_VER.tar.xz" ] || curl -fsSL -o "mesa-$MESA_VER.tar.xz" "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz"
rm -rf "mesa-$MESA_VER"; tar -xJf "mesa-$MESA_VER.tar.xz"
for p in "$HERE"/mesa-patches/*.patch; do [ -e "$p" ] && patch -d "mesa-$MESA_VER" -p1 -s < "$p"; done
NDK=$WORK/android-ndk-$NDK_VER; TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
cat > cross-android-x86_64 <<EOF
[binaries]
ar = '$TC/llvm-ar'
c = ['$TC/x86_64-linux-android$API-clang']
cpp = ['$TC/x86_64-linux-android$API-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
rust = ['$RUST/bin/rustc', '--target', 'x86_64-linux-android', '-C', 'panic=abort']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$TC/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$WORK/pkgconfig', '/usr/bin/pkg-config']
[properties]
bindgen_clang_arguments = ['--target=x86_64-linux-android$API', '--sysroot=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot']
[host_machine]
system = 'android'
cpu_family = 'x86_64'
cpu = 'amd64'
endian = 'little'
EOF
mkdir -p pkgconfig
cd "mesa-$MESA_VER"
# Intel and NVIDIA drivers precompile OpenCL-C kernels at build time: build the host tools
# (mesa_clc, vtn_bindgen2) natively first - they need LLVM/Clang/libclc/SPIRV-LLVM-Translator.
if [ ! -x "$WORK/host-tools/bin/mesa_clc" ]; then
  apt-get install -y -qq llvm-18-dev libclang-18-dev libclc-18-dev libllvmspirvlib-18-dev clang-18 \
    libdrm-dev libexpat1-dev zlib1g-dev >/dev/null
  rm -rf build-host
  meson setup build-host --prefix="$WORK/host-tools" --buildtype release \
    -Dgallium-drivers= -Dvulkan-drivers= -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
    -Dllvm=enabled -Dshared-llvm=enabled -Dmesa-clc=enabled -Dinstall-mesa-clc=true \
    -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true 2>&1 | tail -5
  ninja -C build-host 2>&1 | tail -3
  meson install -C build-host --no-rebuild >/dev/null
fi
export PATH=$WORK/host-tools/bin:$PATH
# libdrm for the target (Mesa won't take it as a subproject here): cross-build into a sysroot
SYS=$WORK/sysroot
if [ ! -f "$SYS/lib64/pkgconfig/libdrm.pc" ]; then
  (cd "$WORK" && { [ -d "libdrm-$LIBDRM_VER" ] || curl -fsSL "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz" | tar -xJ; } \
   && cd "libdrm-$LIBDRM_VER" && rm -rf build-android \
   && meson setup build-android --cross-file ../cross-android-x86_64 --prefix=/ --libdir lib64 --buildtype release \
        -Ddefault_library=static \
        -Dintel=disabled -Damdgpu=enabled -Dradeon=enabled -Dnouveau=disabled -Dvmwgfx=disabled \
        -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dudev=false | tail -3 \
   && ninja -C build-android | tail -2 && DESTDIR=$SYS meson install -C build-android --no-rebuild >/dev/null)
  sed -i "s#^prefix=.*#prefix=$SYS#" "$SYS"/lib64/pkgconfig/*.pc
fi
# libelf for NVK (reads CUDA cubins): the small old libelf Mesa's own Android CI uses
LIBELF=libelf-0.8.13
if [ ! -f "$SYS/lib64/libelf.a" ]; then
  (cd "$WORK" && rm -rf $LIBELF && curl -fsSL -o $LIBELF.tar.gz "https://fossies.org/linux/misc/old/$LIBELF.tar.gz" \
   && echo "4136d7b4c04df68b686570afa26988ac  $LIBELF.tar.gz" | md5sum -c --quiet && tar -xzf $LIBELF.tar.gz && rm $LIBELF.tar.gz \
   && cd $LIBELF && autoreconf -fi >/dev/null 2>&1 \
   && CC=$TC/x86_64-linux-android$API-clang AR=$TC/llvm-ar RANLIB=$TC/llvm-ranlib \
        ./configure -q --host=x86_64-linux-gnu --disable-nls --disable-shared --prefix="$SYS" --libdir="$SYS/lib64" \
   && make -s >/dev/null && make -s install >/dev/null)
fi
sed -i "s#PKG_CONFIG_LIBDIR=[^']*#PKG_CONFIG_LIBDIR=$SYS/lib64/pkgconfig#" ../cross-android-x86_64
rm -rf build-android
meson setup build-android --cross-file ../cross-android-x86_64 \
  --libdir lib64 --buildtype release -Db_ndebug=true \
  -Dplatforms=android -Dplatform-sdk-version=$API -Dandroid-stub=true -Dandroid-libbacktrace=disabled \
  -Dgallium-drivers=iris,crocus,nouveau,zink,virgl,softpipe -Dvulkan-drivers=nouveau,intel_hasvk,amd \
  -Dllvm=disabled -Dgbm=disabled -Dglx=disabled -Degl=enabled -Dgles1=enabled -Dgles2=enabled \
  -Degl-lib-suffix=_mesa -Dgles-lib-suffix=_mesa \
  -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dmesa-clc=system -Dprecomp-compiler=system \
  --force-fallback-for=expat -Dexpat:default_library=static 2>&1 | tail -40
# libdrm/expat are linked statically: Android's "sphal" linker namespace (where apps load EGL/Vulkan
# drivers) only sees LL-NDK + same-process-HAL libs, not the vendor's own libdrm/libexpat.
ninja -C build-android 2>&1 | tail -15
rm -rf "$WORK/install"; DESTDIR=$WORK/install meson install -C build-android --no-rebuild --strip >/dev/null
find "$WORK/install" -name '*.so*' | head -40
