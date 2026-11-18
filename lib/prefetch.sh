# shellcheck shell=bash
# Big downloads, fetched once into the cache. tools/prepare.sh starts them in the background
# (prefetch_start) once its own downloads are done, while the kernel compiles; the step that needs a file calls fetch_file itself, which waits for a running prefetch
# of that file (same lock) instead of downloading it twice, and downloads it if the prefetch failed.

# fetch_file <url> <file> [sha1]: <file> complete (and matching sha1) when it returns 0. Downloads
# to <file>.part and renames, so an interrupted download never looks finished.
fetch_file() {
  local url=$1 f=$2 sum=${3:-}
  mkdir -p "$(dirname "$f")"
  (
    flock 9
    ok() { [ -s "$f" ] && { [ -z "$sum" ] || echo "$sum  $f" | sha1sum -c --quiet >/dev/null 2>&1; }; }
    ok && exit 0
    echo "   downloading $(basename "$f")" >&2
    curl -fL --retry 3 -sS -o "$f.part" "$url" && mv "$f.part" "$f" && ok
  ) 9>"$f.lock"
}

# prefetch_start <cache dir>: the image-independent big downloads (versions.env must be loaded):
# emulator image (~2.2 GB), linux-firmware (~630 MB), Android NDK (~700 MB). Their PIDs go to
# BG_PIDS (churro.sh's exit cleanup stops them).
prefetch_start() {
  local C=$1 e; e=$(basename "${CHURRO_EMU_URL:-x}" .zip)   # unset: versions.env loaded without CHURRO_API
  if [ -n "${CHURRO_EMU_URL:-}" ] && { [ ! -f "$C/emu-vendor-$e/.done" ] || [ ! -f "$C/emu-system-$e/.done" ]; }; then   # lib/emu-image.sh
    fetch_file "$CHURRO_EMU_URL" "$C/$e.zip" "$CHURRO_EMU_SHA1" >/dev/null 2>&1 &
    BG_PIDS="${BG_PIDS:-} $!"
  fi
  if [ ! -f "$C/linux-firmware-$CHURRO_LINUX_FIRMWARE/.unpacked" ]; then
    fetch_file "https://cdn.kernel.org/pub/linux/kernel/firmware/linux-firmware-$CHURRO_LINUX_FIRMWARE.tar.xz" \
      "$C/linux-firmware-$CHURRO_LINUX_FIRMWARE/lf.tar.xz" >/dev/null 2>&1 &
    BG_PIDS="$BG_PIDS $!"
  fi
  if [ ! -d "$C/mesa/android-ndk-$NDK_VER" ]; then
    fetch_file "https://dl.google.com/android/repository/android-ndk-$NDK_VER-linux.zip" "$C/mesa/ndk-$NDK_VER.zip" >/dev/null 2>&1 &
    BG_PIDS="$BG_PIDS $!"
  fi
}
