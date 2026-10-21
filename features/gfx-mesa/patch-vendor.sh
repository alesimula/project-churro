#!/usr/bin/env bash
# Add Mesa (built by gfx/build-mesa.sh) to the vendor partition and make the GL/Vulkan driver
# selectable at boot (androidboot.churro.gfx=native|mesa), instead of the hardcoded
# ro.hardware.egl=angle / ro.hardware.vulkan=intel (Intel Gen12+ only).
# Usage: patch-vendor.sh <extracted vendor tree>       env: CHURRO_MESA=<mesa install dir>
set -euo pipefail
V=$1
M=${CHURRO_MESA:?set CHURRO_MESA to the meson DESTDIR of gfx/build-mesa.sh}
L=$(find "$M" -type d -name lib64 | head -1)
SPHAL=u:object_r:same_process_hal_file:s0
put() { install -D -m 0644 -o root -g root "$1" "$2"; setfattr -n security.selinux -v "$SPHAL" "$2"; }

# 1. drivers: EGL/GLES (loaded by name from lib64/egl), Vulkan HALs (lib64/hw/vulkan.<name>.so)
mkdir -p "$V/lib64/egl"; setfattr -n security.selinux -v u:object_r:vendor_file:s0 "$V/lib64/egl"
for f in "$L"/libEGL_mesa.so "$L"/libGLESv1_CM_mesa.so "$L"/libGLESv2_mesa.so; do
  [ -f "$f" ] && put "$f" "$V/lib64/egl/$(basename "$f")"; done
# Vulkan drivers are big (~20 MB each): NVK (GL on NVIDIA Kepler+ is Zink on top of it), hasvk
# (Intel Gen7-8: Ivy Bridge, Haswell, Broadwell; Google's camera HAL and Chrome need Vulkan) +
# the requested ones (CHURRO_MESA_VULKAN="radeon")
vks=()
for vk in nouveau intel_hasvk ${CHURRO_MESA_VULKAN:-}; do
  [ -f "$L/libvulkan_$vk.so" ] && put "$L/libvulkan_$vk.so" "$V/lib64/hw/vulkan.$vk.so" && vks+=("$V/lib64/hw/vulkan.$vk.so")
done
# hasvk's GPUs for the boot menu (lib/esp.sh picks ro.hardware.vulkan by device ID): Mesa's own
# PCI ID tables, platforms ivb/byt/hsw (Gen7/7.5) and bdw/chv (Gen8).
. "$(dirname "$0")/../../versions.env"
P=$(dirname "$M")/mesa-$MESA_VER/include/pci_ids
if [ -n "${CHURRO_HASVK_IDS:-}" ]; then
  sed -nE 's/^CHIPSET\(0x0*([0-9a-fA-F]+), *(ivb|byt|hsw|bdw|chv)[_,].*/\1/p' "$P"/crocus_pci_ids.h "$P"/iris_pci_ids.h > "$CHURRO_HASVK_IDS"
  [ -s "$CHURRO_HASVK_IDS" ] || { echo "no hasvk GPU IDs in $P" >&2; exit 1; }
  echo "   vendor: Vulkan hasvk for $(wc -l < "$CHURRO_HASVK_IDS") Intel Gen7-8 GPU IDs"
fi

# 2. their non-platform dependencies (libgallium-*.so, libdrm_amdgpu.so, ...), closure
todo=("$V"/lib64/egl/*_mesa.so "${vks[@]}"); added=""
while [ ${#todo[@]} -gt 0 ]; do
  f=${todo[0]}; todo=("${todo[@]:1}"); [ -f "$f" ] || continue
  for n in $(readelf -d "$f" | awk '/NEEDED/ {gsub(/[][]/, "", $NF); print $NF}'); do
    [ -e "$V/lib64/$n" ] && continue
    src=$(find "$M" "${CHURRO_MESA_SYSROOT:-/nonexistent}" -name "$n" -type f 2>/dev/null | head -1)
    [ -n "$src" ] || continue                       # LL-NDK (libc, liblog, libnativewindow, ...)
    put "$src" "$V/lib64/$n"; added="$added $n"; todo+=("$V/lib64/$n")
  done
done

# edit <sed script> <file>: rewrite in place. `sed -i` makes a new file, which drops the SELinux
# xattr on a non-SELinux build host (build.prop ended up without its SELinux label).
edit() { local c; c=$(sed -E "$1" "$2"); printf '%s\n' "$c" > "$2"; }
# 3. graphics props move from build.prop to boot-time selection (see zz-churro-gfx.rc)
edit '/^(ro\.hardware\.egl|ro\.hardware\.vulkan|ro\.hwui\.use_vulkan|debug\.renderengine\.vulkan|debug\.renderengine\.backend)=/d' "$V/build.prop"
# drm_hwcomposer is set to require the KMS COLOR_PIPELINE plane property, which only Panther
# Lake-class display hardware has; elsewhere it rejects every plane. Generic PCs: off.
edit 's/^vendor\.hwc\.drm\.enable_color_pipeline=true$/vendor.hwc.drm.enable_color_pipeline=false/' "$V/build.prop"
# Google tunes the composer for the Lenovo panel: colour mode 13, persistent HDR, log-gamma LUT.
# On generic panels that gives a colour cast / washed-out picture. Force SDR (as GBRUNCH does):
# colour mode 7, no persistent HDR, no log-gamma LUT. `>>` appends in place (keeps the xattr).
edit '/^vendor\.hwc\.drm\.(force_color_mode|persistent_hdr|use_log_gamma_lut)=/d' "$V/build.prop"
printf '%s\n' vendor.hwc.drm.force_color_mode=7 vendor.hwc.drm.persistent_hdr=false \
  vendor.hwc.drm.use_log_gamma_lut=false >> "$V/build.prop"
echo "   vendor: Mesa installed (+libs:$added)"

# 4. every DRM node is a GPU/display device. The image only labels card0/card1/renderD128/129;
# with simpledrm + vgem in front, the real GPU becomes card2 (labelled plain "device") and
# SurfaceFlinger/composer get SELinux denials -> abort loop. In place: keeps the file's xattr.
grep -q 'card\[0-9\]' "$V/etc/selinux/vendor_file_contexts" || cat >> "$V/etc/selinux/vendor_file_contexts" <<'EOF'
/dev/dri/card[0-9]+          u:object_r:gpu_device:s0
/dev/dri/renderD[0-9]+       u:object_r:gpu_device:s0
EOF

# 5. ueventd runs live uevents on a thread pool (parallel_ueventd_main_loop). When the GPU
# driver takes over from simpledrm, simpledrm's "remove card0" and the GPU's "add card0" belong
# to different devices but name the same node: run out of order, the remove deletes the new
# /dev/dri/card0 -> drm_hwcomposer finds no display, boots headless (~1 boot in 2). Sequential.
edit 's/^parallel_ueventd_main_loop enabled$/parallel_ueventd_main_loop disabled/' "$V/etc/ueventd.rc"
