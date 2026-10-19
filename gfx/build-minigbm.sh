#!/usr/bin/env bash
# Build minigbm from source as drop-in replacements for the image's libminigbm_gralloc.so and
# libgbm.so: AOSP external/minigbm (the source of Google's own build, same release branch) plus
# gfx/minigbm-patches/. Google's allocator service, mapper, gralloc0 module and codec/camera HALs
# keep running unchanged on top of them; the patches only change which GPUs minigbm accepts.
# ABI: Google's binaries call libminigbm_gralloc's C++ API with platform libc++ types (std::__1),
# so we link the image's own libc++.so with the NDK's headers switched to that namespace, and
# refuse the result if it doesn't export every symbol Google's libraries export.
# Usage: gfx/build-minigbm.sh <work dir> <extracted vendor tree>   -> <work dir>/out/*.so
set -euo pipefail
W=$(mkdir -p "$1" && cd "$1" && pwd) V=$2
HERE=$(cd "$(dirname "$0")" && pwd)
. "$(dirname "$0")/../versions.env"
NDK=${CHURRO_NDK:-${CHURRO_MESA:?}/../android-ndk-$NDK_VER}
SYS=${CHURRO_MESA_SYSROOT:?}                       # static libdrm from build-mesa.sh
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
API=35 SDK=37                                      # NDK target / Android 17 (Google's build flag)

# --- sources: pinned android17-release revisions ---
G=https://android.googlesource.com/platform
get() {  # <dest> <repo> <rev> [path]
  [ -d "$W/src/$1" ] && return 0
  local u="$G/$2/+archive/$3${4:+/$4}.tar.gz" i
  for i in 1 2 3; do curl -fsSL -o "$W/dl.tgz" "$u" && break; [ $i = 3 ] && { echo "download failed: $u" >&2; exit 1; }; sleep 5; done
  rm -rf "$W/src/$1.tmp"; mkdir -p "$W/src/$1.tmp"; tar -xzmf "$W/dl.tgz" -C "$W/src/$1.tmp"; rm "$W/dl.tgz"; mv "$W/src/$1.tmp" "$W/src/$1"
}
HI=0162af698935100a590b7359581ac8b1b80693e5
get minigbm    external/minigbm ce79bbee67b3e2ea7abb110e1415e9ceceaa6471
get cutils     system/core 545d2487e38192a2ce25040897ced877cf6b4f53 libcutils/include
get libsystem  system/core 545d2487e38192a2ce25040897ced877cf6b4f53 libsystem/include
get libsync    system/core 545d2487e38192a2ce25040897ced877cf6b4f53 libsync/include
get liblog     system/logging d35ba620451b28512f46ebb5421f783fd77968d5 liblog/include
get hardware   hardware/libhardware 97ee3e33ec5ba48c0eca8341ed377ac4497a0678 include_all
get nwindow    frameworks/native ae266dcb706d083868578cfedce381ef44488a07 libs/nativewindow/include
get nbase      frameworks/native ae266dcb706d083868578cfedce381ef44488a07 libs/nativebase/include
get arect      frameworks/native ae266dcb706d083868578cfedce381ef44488a07 libs/arect/include
get binder-cpp frameworks/native ae266dcb706d083868578cfedce381ef44488a07 libs/binder/ndk/include_cpp
get binder-ndk frameworks/native ae266dcb706d083868578cfedce381ef44488a07 libs/binder/ndk/include_ndk
get dmabufheap system/memory/libdmabufheap 09fe72b6ce0feead1b97c2859979b125f815d9b0 include
get libbase    system/libbase fef4173e19d97cd4b4fc09a06bccbf800d0d3937 include
get aidl-gc7   hardware/interfaces $HI graphics/common/aidl/aidl_api/android.hardware.graphics.common/7
get aidl-hc2   hardware/interfaces $HI common/aidl/aidl_api/android.hardware.common/2
if [ ! -x "$W/bt/aidl" ]; then   # AIDL compiler from the SDK build-tools
  curl -fsSL -o "$W/bt.zip" https://dl.google.com/android/repository/build-tools_r36_linux.zip
  rm -rf "$W/bt.tmp"; unzip -q "$W/bt.zip" -d "$W/bt.tmp"; rm "$W/bt.zip"; mv "$W/bt.tmp"/* "$W/bt"; rmdir "$W/bt.tmp"
fi

# --- AIDL NDK headers (graphics.common V7 + its android.hardware.common V2 import) ---
B=$W/build; rm -rf "$B"; mkdir -p "$B/gen" "$B/link" "$B/cxx" "$W/out"
for d in aidl-hc2:2 aidl-gc7:7; do
  r=$W/src/${d%:*}
  "$W/bt/aidl" --lang=ndk --structured --stability=vintf --version="${d#*:}" --hash="$(tail -1 "$r/.hash")" \
    -I "$W/src/aidl-hc2" -I "$W/src/aidl-gc7" -h "$B/gen" -o "$B/gen/src" $(find "$r" -name '*.aidl')
done

# --- minigbm + patches ---
cp -r "$W/src/minigbm" "$B/minigbm"
for p in "$HERE"/minigbm-patches/*.patch; do patch -d "$B/minigbm" -p1 -s < "$p"; done

# libc++: NDK headers, platform ABI namespace, the image's libc++.so
sed 's/_LIBCPP_ABI_NAMESPACE __ndk1/_LIBCPP_ABI_NAMESPACE __1/' \
  "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/c++/v1/__config_site" > "$B/cxx/__config_site"
for l in libc++ libcutils libdmabufheap; do ln -s "$V/lib64/$l.so" "$B/link/$l.so"; done
# link-time stub: the NDK's libsync.so lacks the platform's sync_wait (the real one is in /system)
echo 'int sync_wait(int fd, int timeout) { return fd + timeout; }' | \
  "$TC/x86_64-linux-android$API-clang" -shared -x c - -o "$B/link/libsync.so" -Wl,-soname,libsync.so

M=$B/minigbm
INC="-I$M -I$M/external -I$W/src/cutils -I$W/src/libsystem -I$W/src/libsync -I$W/src/liblog
  -I$W/src/hardware -I$W/src/nwindow -I$W/src/nbase -I$W/src/arect -I$W/src/dmabufheap -I$B/gen
  -I$W/src/binder-cpp -I$W/src/binder-ndk -I$W/src/libbase
  -I$SYS/include -I$SYS/include/libdrm"
DEF="-DDRV_I915 -DDRV_XE -DHAS_DMABUF_SYSTEM_HEAP -DANDROID_API_LEVEL=$SDK -D_GNU_SOURCE=1
  -D_FILE_OFFSET_BITS=64 -D__ANDROID_VNDK__ -D__ANDROID_VENDOR__"
CFL="-O2 -fPIC -Wall -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function -Wno-invalid-offsetof"
CORE="amdgpu backend_mock dma_heap drv drv_array_helpers drv_helpers dumb_driver i915 mediatek msm
  rockchip vc4 virtgpu virtgpu_cross_domain virtgpu_virgl xe"
cc()  { "$TC/x86_64-linux-android$API-clang" $CFL $DEF $INC -std=gnu11 -c "$1" -o "$2"; }
cxx() { "$TC/x86_64-linux-android$API-clang++" $CFL $DEF -isystem "$B/cxx" $INC -std=c++20 -fvisibility-inlines-hidden -c "$1" -o "$2"; }
for f in $CORE gbm gbm_helpers minigbm_helpers; do cc "$M/$f.c" "$B/$f.o"; done
for f in cros_gralloc_buffer cros_gralloc_driver cros_gralloc_helpers; do cxx "$M/cros_gralloc/$f.cc" "$B/$f.o"; done
core=$(for f in $CORE; do echo "$B/$f.o"; done)
ld() { local so=$1; shift; "$TC/x86_64-linux-android$API-clang++" -shared -nostdlib++ -Wl,-soname,$so -Wl,--as-needed \
         -o "$W/out/$so" "$@" "$SYS/lib64/libdrm.a" -L"$B/link" -lc++ -lcutils -llog; }
ld libminigbm_gralloc.so $core "$B"/cros_gralloc_*.o -ldmabufheap -lsync -lnativewindow
ld libgbm.so $core "$B/gbm.o" "$B/gbm_helpers.o" "$B/minigbm_helpers.o"
"$TC/llvm-strip" --strip-unneeded "$W"/out/*.so

# --- ABI gate: every symbol the image's binaries take from Google's library must exist in ours ---
syms() { nm -D "$@" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' | sort -u; }
for so in libminigbm_gralloc.so libgbm.so; do
  users=$(grep -rlaF "$so" "$V/bin" "$V/lib64" | while read -r f; do
            readelf -dW "$f" 2>/dev/null | grep -qF "[$so]" && echo "$f"; done || true)
  need=$(for f in $users; do syms --undefined-only "$f"; done | sort -u | comm -12 - <(syms --defined-only "$V/lib64/$so"))
  miss=$(comm -23 <(echo "$need") <(syms --defined-only "$W/out/$so"))
  [ -z "$miss" ] || { echo "$so: symbols the image needs but this build lacks:" >&2; echo "$miss" | head -20 >&2; exit 1; }
  echo "   $so: $(echo "$need" | grep -c .) symbols used by $(echo "$users" | grep -c .) image binaries, all present"
done
echo "   minigbm built: $(ls "$W"/out | tr '\n' ' ')"
