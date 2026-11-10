#!/usr/bin/env bash
# Default display density from the PC's screen instead of a fixed one: Googlebook images set
# ro.sf.lcd_density for their own panel (Lenovo Googlebook 15: 240 for 2.8K 15.3"), so 1366x768
# laptops got huge UI (512 dp tall: Chrome's phone layout, whose address bar crashes).
# churro-density (run at `on post-fs`, before SurfaceFlinger reads the property) computes it from the
# main screen's size as the GPU driver reports it (churro-drm); the image's value, if any, is only
# the fallback when no screen is found.
# Android's Display size setting stays on top.
set -euo pipefail
T=$1; F=$(dirname "$0")
CFG=u:object_r:vendor_configs_file:s0
ref=$(sed -n 's/^ro\.sf\.lcd_density=//p' "$T/build.prop" | tail -1)
# in place: sed -i would drop build.prop's SELinux label (see gfx-mesa)
[ -z "$ref" ] || { c=$(sed '/^ro\.sf\.lcd_density=/d' "$T/build.prop"); printf '%s\n' "$c" > "$T/build.prop"; }

# a value in another partition's build.prop is set before `on init` too (ro.: ours would fail)
for p in system_a system_ext_a product_a odm_a; do
  read -r off size < <(python3 "$CHURRO_HERE/lib/lpinfo.py" "$CHURRO_SUPER" "$p" 2>/dev/null) || continue
  L=$(losetup -f --show -r -o "$off" --sizelimit "$size" "$CHURRO_SUPER")
  for f in /build.prop /system/build.prop /etc/build.prop /prop.default /system/etc/prop.default; do
    v=$("$EROFS_BIN/dump.erofs" --cat --path=$f "$L" 2>/dev/null | sed -n 's/^ro\.sf\.lcd_density=//p' | tail -1) || true
    [ -z "$v" ] || echo "   vendor: display-density: WARNING ro.sf.lcd_density=$v in ${p%_a}$f wins: density stays $v (remove it there)"
  done
  losetup -d "$L"
done

tr -d '\r' < "$F/churro-density" > "$T/bin/churro-density"   # Windows checkouts: CRLF
chown root:2000 "$T/bin/churro-density"; chmod 0755 "$T/bin/churro-density"
# get_variant_audio's label: Google's policy gives that domain vendor.audio.* (Google ships no
# program for it; audio-generic's script uses it too)
setfattr -n security.selinux -v u:object_r:get_variant_audio_exec:s0 "$T/bin/churro-density"
# churro-drm: static, like churro-mixer, and labelled the same way (get_variant_audio runs it)
${CC:-cc} -static -Os -s -Wall -o "$T/bin/churro-drm" "$F/churro-drm.c"
chown root:2000 "$T/bin/churro-drm"; chmod 0755 "$T/bin/churro-drm"
setfattr -n security.selinux -v u:object_r:vendor_toolbox_exec:s0 "$T/bin/churro-drm"

S=$T/etc/selinux; V=$(cat "$S/plat_sepolicy_vers.txt")
cat >> "$S/vendor_sepolicy.cil" <<EOF
; Project Churro display-density: churro-drm (get_variant_audio) asks the GPU drivers for their
; screens (/dev/dri/card*), makes them probe outputs they haven't yet ("detect" to
; /sys/class/drm/*/status: Google's policy lets it read sysfs, not write); its lines go to the
; boot log (/dev/kmsg). Opening a DRM device makes the kernel check CAP_SYS_ADMIN (only to mark
; the file "authenticated", not needed here): not granted, not logged.
(allow get_variant_audio sysfs_$V (file (write)))
(allow get_variant_audio gpu_device_$V (dir (search getattr open read)))
(allow get_variant_audio gpu_device_$V (chr_file (getattr open read write ioctl)))
(allow get_variant_audio kmsg_device_$V (chr_file (getattr open write append)))
(dontaudit get_variant_audio self (capability (sys_admin)))
EOF
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256

R=$T/etc/init/churro-density.rc
{ cat <<RC
# Project Churro display-density: ro.sf.lcd_density from the main screen (/vendor/bin/churro-density)
service vendor.churro.density /vendor/bin/churro-density
    user root
    group root graphics
    oneshot
    disabled

# waits (max 5 s) for a GPU driver, has it probe its outputs, computes the density
on post-fs
    exec_start vendor.churro.density
RC
  # "<event> && property:" = checked when late-fs starts, before SurfaceFlinger (class core, on
  # boot). A plain property trigger would come too late: init queues property actions only after
  # all of late-init's stages (boot included). Literal values: vendor_init may set
  # ro.sf.lcd_density but can't read vendor.audio.* for \${}.
  for d in $(seq 100 4 640); do
    printf '\non late-fs && property:vendor.audio.churro.density=%s\n    setprop ro.sf.lcd_density %s\n' $d $d
  done
  # after the above (same stage, file order): only takes effect when no screen was found
  [ -z "$ref" ] || printf '\n# no screen found: keep the image value (ro: no-op once set)\non late-fs\n    setprop ro.sf.lcd_density %s\n' "$ref"
  } > "$R"
chown root:root "$R"; chmod 0644 "$R"; setfattr -n security.selinux -v "$CFG" "$R"
echo "   vendor: display-density: computed at boot (no screen found: ${ref:-SurfaceFlinger default})"
