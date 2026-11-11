#!/usr/bin/env bash
# "Install to an internal disk" from the stick's boot menu (lib/esp.sh adds the entries):
# /vendor/bin/churro-install copies the running stick to an internal disk, or updates an install
# there, with Android's own tools. init runs it at `on init` instead of going on with the boot
# when the entry set androidboot.churro.install: by then ueventd has loaded the drivers (disks,
# keyboard) and nothing else runs; exec_start holds the boot until it powers the PC off.
set -euo pipefail
T=$1; F=$(dirname "$0"); S=$T/etc/selinux; V=$(cat "$S/plat_sepolicy_vers.txt")

tr -d '\r' < "$F/churro-install" > "$T/bin/churro-install"   # Windows checkouts: CRLF
chown root:2000 "$T/bin/churro-install"; chmod 0755 "$T/bin/churro-install"
setfattr -n security.selinux -v u:object_r:churro_install_exec:s0 "$T/bin/churro-install"

R=$T/etc/init/churro-install.rc
cat > "$R" <<'RC'
# Project Churro disk-install: the installer of the "Install to an internal disk" boot entries
# (/vendor/bin/churro-install), on the text console; it ends with a power off
service vendor.churro.install /vendor/bin/churro-install
    user root
    group root
    console tty0
    oneshot
    disabled

on init && property:ro.boot.churro.install=new
    exec_start vendor.churro.install

on init && property:ro.boot.churro.install=update
    exec_start vendor.churro.install
RC
chown root:root "$R"; chmod 0644 "$R"; setfattr -n security.selinux -v u:object_r:vendor_configs_file:s0 "$R"

# Its own domain, entered only by init running that one file (same rules as Google's vendor
# services), and permissive: it partitions and writes whole disks, mounts their ESP, powers off.
# shortcut: permissive instead of a rule per access; the denials it would have had are logged
# (permissive=1) in boot.log of an install run: turn those into allow rules, then drop typepermissive.
cat >> "$S/vendor_sepolicy.cil" <<EOF
; Project Churro disk-install: /vendor/bin/churro-install (boot menu "Install to an internal disk")
(type churro_install)
(roletype object_r churro_install)
(type churro_install_exec)
(roletype object_r churro_install_exec)
(typeattributeset domain (churro_install))
(typeattributeset exec_type (churro_install_exec))
(typeattributeset file_type (churro_install_exec))
(typeattributeset vendor_file_type (churro_install_exec))
(typepermissive churro_install)
(allow init_$V churro_install_exec (file (read getattr map execute open)))
(allow init_$V churro_install (process (transition)))
(allow churro_install churro_install_exec (file (read getattr map execute open entrypoint)))
(dontaudit init_$V churro_install (process (noatsecure)))
(allow init_$V churro_install (process (siginh rlimitinh)))
(typetransition init_$V churro_install_exec process churro_install)
EOF
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256
echo "   vendor: disk-install: installer for the boot menu's \"Install to an internal disk\""
