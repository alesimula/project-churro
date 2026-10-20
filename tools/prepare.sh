#!/usr/bin/env bash
# Prepare everything a full Churro conversion needs, derived from the input image itself:
#   - the GKI build id / source commit / toolchain revisions (from the kernel's version string,
#     its IKCONFIG and Google's public build manifest on ci.android.com)
#   - kernel source + clang + rustc + bindgen (+ pahole) at exactly those revisions
#   - a Churro kernel built with kmod/profiles/<profile>.conf, and module packs from it
#   - Mesa for Android (gfx/build-mesa.sh)
# Everything lands in $CHURRO_CACHE (default /var/cache/churro); re-runs reuse it.
# Usage: tools/prepare.sh <recovery.bin> [kernel profile=generic]
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMG=$1 PROF=${2:-generic}
C=${CHURRO_CACHE:-/var/cache/churro}; mkdir -p "$C"
. "$HERE/lib/bootimg.sh"; . "$HERE/lib/deps.sh"; deps_ensure   # also when run on its own
log() { echo ">> $*"; }
G="https://android.googlesource.com"

# --- 1. kernel identity from the image ---
L=$(losetup -f --show -r -P "$IMG"); trap 'losetup -d "$L"' EXIT; sleep 1
n=$(sgdisk -p "$L" | awk '$NF == "boot_a" {print $1}')
W=$C/image; mkdir -p "$W"; bootimg_extract "${L}p$n" "$W"
for t in extract-ikconfig extract-vmlinux; do
  [ -s "$C/$t" ] || curl -fsSL --retry 3 "https://raw.githubusercontent.com/torvalds/linux/v6.18/scripts/$t" -o "$C/$t"
done
bash "$C/extract-ikconfig" "$W/kernel" > "$W/ikconfig"
bash "$C/extract-vmlinux" "$W/kernel" > "$W/vmlinux" 2>/dev/null
REL=$(strings "$W/vmlinux" | grep -oE 'Linux version [^ ]+' | head -1 | cut -d' ' -f3)
BID=${REL##*-ab}; log "image kernel $REL (GKI build $BID)"
[ -f "$C/manifest_$BID.xml" ] || curl -fsSL -o "$C/manifest_$BID.xml" "https://ci.android.com/builds/submitted/$BID/kernel_x86_64/latest/raw/manifest_$BID.xml"
rev() { grep -oE "<project [^>]*name=\"$1\"[^>]*" "$C/manifest_$BID.xml" | grep -oE 'revision="[^"]+"' | cut -d'"' -f2; }
CLANG_NAME=clang-$(grep -oE 'based on r[0-9a-z]+' "$W/ikconfig" | head -1 | cut -d' ' -f3)
RUST_VER=$(grep -oE 'rustc [0-9.]+' "$W/ikconfig" | head -1 | cut -d' ' -f2)
RUST_BUILD=$(grep -oE 'Toolchain version [0-9]+' "$W/ikconfig" | head -1 | awk '{print $3}')
PAHOLE=v$(grep -oE 'CONFIG_PAHOLE_VERSION=[0-9]+' "$W/ikconfig" | cut -d= -f2 | sed -E 's/^([0-9])([0-9]+)$/\1.\2/')

# --- 2. sources + toolchains ---
S=$C/src-$BID; mkdir -p "$S"
# fetch_tar <url> <dir>: download (3 tries; googlesource +archive can't resume) and extract;
# <dir> only appears once complete, so an interrupted run never leaves a half tree behind.
fetch_tar() {
  local i; for i in 1 2 3; do curl -fsSL -o "$2.tgz" "$1" && break; [ $i = 3 ] && return 1; sleep 5; done
  rm -rf "$2.tmp" && mkdir -p "$2.tmp" && tar -xzmf "$2.tgz" -C "$2.tmp" && rm -f "$2.tgz" && mv "$2.tmp" "$2"
}
[ -d "$S/common" ] || { log "kernel/common @ $(rev kernel/common)"; fetch_tar "$G/kernel/common/+archive/$(rev kernel/common).tar.gz" "$S/common"; }
[ -d "$S/clang" ] || { log "$CLANG_NAME"; fetch_tar "$G/platform/prebuilts/clang/host/linux-x86/+archive/$(rev platform/prebuilts/clang/host/linux-x86)/$CLANG_NAME.tar.gz" "$S/clang"; }
if [ ! -d "$S/rust" ]; then
  RREV=$(rev platform/prebuilts/rust-toolchain/linux-x86)
  for d in $(curl -fsSL "$G/platform/prebuilts/rust-toolchain/linux-x86/+/$RREV/?format=JSON" | tail -c +5 | grep -oE "\"$RUST_VER[^\"]*\"" | tr -d '"' | sort -r); do
    fetch_tar "$G/platform/prebuilts/rust-toolchain/linux-x86/+archive/$RREV/$d.tar.gz" "$S/rust-$d"
    if "$S/rust-$d/bin/rustc" --version | grep -q "$RUST_BUILD"; then mv "$S/rust-$d" "$S/rust"; log "rust $d"; break; fi
    rm -rf "$S/rust-$d"
  done
  [ -d "$S/rust" ] || { echo "no rust toolchain matching build $RUST_BUILD" >&2; exit 1; }
fi
mkdir -p "$S/bin"
[ -x "$S/bin/bindgen" ] || { curl -fsSL "$G/platform/prebuilts/clang-tools/+/$(rev platform/prebuilts/clang-tools)/linux-x86/bin/bindgen?format=TEXT" | base64 -d > "$S/bin/bindgen.tmp"
  chmod +x "$S/bin/bindgen.tmp"; mv "$S/bin/bindgen.tmp" "$S/bin/bindgen"; }
[ -x "$S/bin/pahole" ] || PAHOLE_VER=$PAHOLE bash "$HERE/tools/build-pahole.sh" "$S/bin"

# --- 3. Churro kernel + module packs ---
# cache key includes profile + patches + build script + the distro config tag (versions.env):
# changing any of them rebuilds the kernel. Only that one value, so other version bumps don't.
. "$HERE/versions.env"
KH=$({ cat "$HERE/kmod/profiles/$PROF.conf" "$HERE/kmod/build-kernel.sh" "$HERE"/kmod/patches/*.patch 2>/dev/null; echo "$ARCH_LINUX_CONFIG_TAG"; } | md5sum | cut -c1-8)
K=$C/kernel-$PROF-$BID-$KH
bash "$HERE/tools/extract-certs.sh" "$W/vmlinux" > "$W/gki-certs.pem"
grep -q BEGIN "$W/gki-certs.pem" || { echo "no signing certificate found in the image kernel" >&2; exit 1; }
[ -f "$K/kernel" ] || CHURRO_GKI_CERTS=$W/gki-certs.pem bash "$HERE/kmod/build-kernel.sh" "$S/common" "$S/clang" "$S/rust" "$S/bin" "$W/ikconfig" "$REL" "$PROF" "$K"
[ -f "$K/Module.symvers" ] || cp "$S/common/out-kernel-$PROF/Module.symvers" "$K/"   # drivers-extra's ABI check
# kABI check: every symbol Google's GKI exports must keep its CRC, or prebuilt modules break
[ -f "$C/vmlinux.symvers-$BID" ] || curl -fsSL -o "$C/vmlinux.symvers-$BID" "https://ci.android.com/builds/submitted/$BID/kernel_x86_64/latest/raw/vmlinux.symvers"
bad=$(awk 'NR==FNR {crc[$2]=$1; next} ($2 in crc) && crc[$2] != $1 {n++; if (n<=5) print "   CRC differs: " $2 > "/dev/stderr"} END {print n+0}' \
      "$C/vmlinux.symvers-$BID" "$S/common/out-kernel-$PROF/Module.symvers")
log "kABI check: $bad of $(wc -l < "$C/vmlinux.symvers-$BID") GKI exports differ"
[ "$bad" = 0 ] || { echo "kABI broken: the image's prebuilt modules won't load. Fix the profile ($PROF)." >&2; rm -rf "$K"; exit 1; }
# superseded kernels of this image (one per profile/patch change, ~70-280 MB each): only $K is used
for k in "$C/kernel-$PROF-$BID-"*; do [ "$k" = "$K" ] || rm -rf "$k"; done
MD=$(ls -d "$K"/modroot/lib/modules/*/)
P=$C/packs-$PROF-$BID; rm -rf "$P"
# gpu: no i915 here. As a first-stage pack it loaded on every machine: it wedged Arrow Lake
# (claimed the iGPU before xe, no firmware) and its drm_display_helper replaced the one xe links
# against. i915 now ships via drivers-extra (vendor_dlkm, linked to Google's drm_display_helper,
# aliases limited to GPUs the image's xe doesn't bind), so it only loads on pre-Gen12 Intel.
# No vgem either: loaded first, it took renderD128 everywhere, and Google's VA-API video decoder
# opens only that node (all hardware video decoding failed). gfx-soft.rc loads it when needed.
bash "$HERE/tools/make-pack.sh" "$MD" "$P/gpu" virtio-gpu
bash "$HERE/tools/make-pack.sh" "$MD" "$P/storage" ahci ata_piix ata_generic vmd sdhci-acpi sdhci-pci
bash "$HERE/tools/make-pack.sh" "$MD" "$P/virt" virtio_pci virtio_input
# opt-in (auto --packs ...,wifi): replaces the image's out-of-tree cfg80211/mac80211, so the
# vendor iwlwifi stops loading. Only firmware-less drivers: first stage can't load firmware.
bash "$HERE/tools/make-pack.sh" "$MD" "$P/wifi" cfg80211 mac80211 ath9k

# --- 4. Mesa (rebuilt when its build script or patches change; NVK's Rust parts use the
#     kernel's Android Rust toolchain + bindgen) ---
MH=$({ cat "$HERE/gfx/build-mesa.sh" "$HERE"/gfx/mesa-patches/*.patch 2>/dev/null; echo "$MESA_VER $LIBDRM_VER $NDK_VER"; } | md5sum | cut -c1-8)
if [ ! -f "$C/mesa/.built-$MH" ]; then
  CHURRO_RUST=$S/rust CHURRO_BINDGEN=$S/bin CHURRO_CLANG=$S/clang bash "$HERE/gfx/build-mesa.sh" "$C/mesa"
  rm -f "$C"/mesa/.built-*; touch "$C/mesa/.built-$MH"
fi

cat > "$C/prepared-$BID.env" <<EOF
CHURRO_KERNEL=$K
CHURRO_PACK_DIR=$P
CHURRO_MESA=$C/mesa/install
CHURRO_MESA_SYSROOT=$C/mesa/sysroot
EOF
log "ready: $C/prepared-$BID.env"
