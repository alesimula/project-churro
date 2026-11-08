#!/usr/bin/env bash
# SELinux for the boot logger (logger.c): it starts before policy load, so it stays in the
# "kernel" domain, which may not read kmsg nor write vfat files. Add exactly that to the vendor
# policy and drop the precompiled policy so init compiles it on-device (a few seconds per boot).
set -euo pipefail
T=$1; S=$T/etc/selinux
V=$(cat "$S/plat_sepolicy_vers.txt")
cat >> "$S/vendor_sepolicy.cil" <<EOF
; Project Churro debug-log: boot logger (kernel domain) -> CHURRO-LOG partition
(allow kernel_$V vfat_$V (dir (search getattr open read write add_name remove_name)))
(allow kernel_$V vfat_$V (file (getattr open read write append create setattr rename unlink ioctl lock)))
(allow kernel_$V vfat_$V (filesystem (mount getattr)))
(allow kernel_$V tmpfs_$V (dir (search getattr open read write add_name mounton)))
(allow kernel_$V tmpfs_$V (chr_file (getattr open read write ioctl)))
(allow kernel_$V tmpfs_$V (blk_file (create getattr open read write ioctl)))
(allow kernel_$V self (capability (sys_admin mknod net_admin)))
(allow kernel_$V sysfs_$V (dir (search getattr open read)))
(allow kernel_$V sysfs_$V (file (getattr open read)))
; logcat.log: read logd's reader socket, reached through /proc/1/root (init's mount namespace)
(allow kernel_$V proc_$V (dir (search getattr open read)))
(allow kernel_$V init_$V (dir (search getattr)))
(allow kernel_$V init_$V (lnk_file (read getattr)))
(allow kernel_$V init_$V (file (read)))
(allow kernel_$V device_$V (dir (search getattr)))
(allow kernel_$V socket_device_$V (dir (search getattr)))
(allow kernel_$V logdr_socket_$V (sock_file (write getattr)))
(allow kernel_$V logd_$V (unix_stream_socket (connectto)))
(allow kernel_$V self (unix_stream_socket (create connect read write getopt setopt shutdown)))
; audio.log: ALSA playback/codec state from /proc/asound
(allow kernel_$V proc_asound_$V (dir (search getattr open read)))
(allow kernel_$V proc_asound_$V (file (getattr open read)))
EOF
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256
echo "   vendor: SELinux rules for the boot logger, precompiled policy removed"
