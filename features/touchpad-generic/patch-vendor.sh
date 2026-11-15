#!/usr/bin/env bash
# Touchpads behave like on a desktop, on any PC (docs/03, "touchpad-generic"):
# 1. churro-touchpad (service, from post-fs-data): learns the real size of touchpads whose driver
#    declares a smaller one (e.g. hid-asus on unlisted ASUS docks: the right part of the pad was
#    dead), stores it in /data/vendor/churro/touchpad-ranges and applies it (EVIOCSABS + a
#    remove/add uevent so Android's input system reopens the pad). Stops watching a pad after
#    15 minutes of touching with nothing out of range.
# 2. for every user, at boot completed and when user 10 (the first real user) is unlocked, two
#    touchpad settings Android leaves off are turned on unless they were ever set (the user's
#    choice in Settings > Touchpad stays): tap dragging (tap twice and hold to drag) and the
#    bottom-right corner click as right click.
# churro.sh auto --stock-touchpad leaves this feature out (Googlebook's own behaviour).
set -euo pipefail
T=$1; F=$(dirname "$0")
CFG=u:object_r:vendor_configs_file:s0

${CC:-cc} -static -Os -s -Wall -Wextra -o "$T/bin/churro-touchpad" "$F/churro-touchpad.c"
chown root:2000 "$T/bin/churro-touchpad"; chmod 0755 "$T/bin/churro-touchpad"
setfattr -n security.selinux -v u:object_r:churro_touchpad_exec:s0 "$T/bin/churro-touchpad"

mkdir -p "$T/etc/churro"; setfattr -n security.selinux -v "$CFG" "$T/etc/churro"
S=$T/etc/churro/touchpad-settings.sh
cat > "$S" <<'SH'
#!/system/bin/sh
# Project Churro touchpad-generic: desktop defaults for two touchpad settings, for every user,
# only while unset ("null"): a choice made in Settings stays.
for u in $(pm list users | sed -n 's/.*UserInfo{\([0-9]*\):.*/\1/p'); do
  for k in touchpad_tap_dragging touchpad_right_click_zone; do
    [ "$(settings get --user $u system $k)" = null ] && settings put --user $u system $k 1
  done
done
exit 0
SH
chown root:root "$S"; chmod 0644 "$S"; setfattr -n security.selinux -v "$CFG" "$S"

V=$(cat "$T/etc/selinux/plat_sepolicy_vers.txt")
cat >> "$T/etc/selinux/vendor_sepolicy.cil" <<CIL
; Project Churro touchpad-generic: churro-touchpad's own domain, entered only by init running it.
; It reads and resizes touchpads (/dev/input: ioctl EVIOCGABS/EVIOCSABS), watches the directory
; for new ones, reads the DMI product name and writes a touchpad's sysfs "uevent" file (remove +
; add: ueventd recreates the node, Android reopens it). A uevent file carries its bus's label
; (sysfs_usb for a USB pad, plain sysfs for i2c/PS2), so any sysfs label is allowed except
; sysfs_usermodehelper, which a neverallow reserves for init/ueventd. It opens uevent with
; O_APPEND, which SELinux checks as "append".
; Keeps its store in /data/vendor/churro and logs to /dev/kmsg.
(type churro_touchpad)
(roletype object_r churro_touchpad)
(type churro_touchpad_exec)
(roletype object_r churro_touchpad_exec)
(typeattributeset domain (churro_touchpad))
(typeattributeset exec_type (churro_touchpad_exec))
(typeattributeset file_type (churro_touchpad_exec))
(typeattributeset vendor_file_type (churro_touchpad_exec))
(allow init_$V churro_touchpad_exec (file (read getattr map execute open)))
(allow init_$V churro_touchpad (process (transition)))
(allow churro_touchpad churro_touchpad_exec (file (read getattr map execute open entrypoint)))
(dontaudit init_$V churro_touchpad (process (noatsecure)))
(allow init_$V churro_touchpad (process (siginh rlimitinh)))
(typetransition init_$V churro_touchpad_exec process churro_touchpad)
(allow churro_touchpad input_device_$V (dir (search getattr open read watch)))
(allow churro_touchpad input_device_$V (chr_file (getattr open read write ioctl)))
(typeattribute churro_touchpad_sysfs)
(typeattributeset churro_touchpad_sysfs (and (sysfs_type) (not (sysfs_usermodehelper_$V))))
(allow churro_touchpad churro_touchpad_sysfs (file (getattr open read write append)))
(allow churro_touchpad vendor_data_file_$V (dir (search getattr open read write add_name remove_name create)))
(allow churro_touchpad vendor_data_file_$V (file (getattr open read write create rename unlink)))
(allow churro_touchpad kmsg_device_$V (chr_file (getattr open write append)))
CIL
rm -f "$T"/etc/selinux/precompiled_sepolicy "$T"/etc/selinux/precompiled_sepolicy.*.sha256

R=$T/etc/init/churro-touchpad.rc
cat > "$R" <<'RC'
# Project Churro touchpad-generic (features/touchpad-generic/patch-vendor.sh)
service vendor.churro.touchpad /vendor/bin/churro-touchpad
    user root
    group root input
    disabled

# init.rc's own post-fs-data actions (which make /data/vendor) run first; Android's input system
# starts later (zygote-start), so the stored sizes are in place before it opens the pads
on post-fs-data
    start vendor.churro.touchpad

# shell domain + uid: the one that may run `settings` and `pm` (as AOSP's console service does)
service vendor.churro.touchpad-settings /system/bin/sh /vendor/etc/churro/touchpad-settings.sh
    user shell
    group shell
    seclabel u:r:shell:s0
    oneshot
    disabled

on property:sys.boot_completed=1
    start vendor.churro.touchpad-settings
RC
chown root:root "$R"; chmod 0644 "$R"; setfattr -n security.selinux -v "$CFG" "$R"
echo "   vendor: touchpad-generic: churro-touchpad (learns touchpad sizes), tap dragging + corner right click on by default"
