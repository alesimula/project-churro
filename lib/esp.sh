# shellcheck shell=bash
# Populate the image's (empty) EFI-SYSTEM partition with GRUB + kernel + initrd.
# Googlebooks boot through depthcharge, which never touches the ESP, so we own it.

# esp_build <esp block device> <stage dir with kernel, initrd.img> <vendor cmdline> <boot_source>
esp_build() {
  local dev=$1 stage=$2 vcmd=$3 bsrc=$4 mnt
  mkfs.vfat -n CHURRO "$dev" >/dev/null
  mnt=$(mktemp -d); mount "$dev" "$mnt"
  mkdir -p "$mnt/EFI/BOOT" "$mnt/churro"

  # Tiny embedded config: find the partition GRUB was loaded from, hand over to the editable cfg.
  local stub; stub=$(mktemp)
  cat > "$stub" <<'EOF'
regexp --set=1:root '^\(([^)]+)\)' "$cmdpath"
if [ -z "$root" -o ! -f "($root)/churro/grub.cfg" ]; then search --no-floppy --file --set=root /churro/grub.cfg; fi
echo "Churro: cmdpath=$cmdpath root=$root"
configfile "($root)/churro/grub.cfg"
EOF
  grub-mkstandalone -O x86_64-efi -o "$mnt/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt part_msdos fat normal linux echo all_video efi_gop efi_uga probe regexp configfile test cat efifwsetup search search_fs_file sleep setpci" \
    --locales="" --fonts="" "boot/grub/grub.cfg=$stub"
  rm -f "$stub"

  cp "$stage/kernel" "$mnt/churro/kernel"
  cp "$stage/initrd.img" "$mnt/churro/initrd.img"

  # env.cfg is the per-install knob file (the installer flips boot_source to internal).
  cat > "$mnt/churro/env.cfg" <<EOF
set boot_source=$bsrc
set extra_args="${CHURRO_EXTRA_ARGS:-}"
set default=${CHURRO_DEFAULT_ENTRY:-0}
EOF
  # Intel iGPUs the image's xe driver binds (device IDs from drivers-extra) keep Google's stack;
  # any other Intel iGPU is pre-Gen12 -> our i915 + Mesa. setpci prints hex in no fixed case or
  # width: match both cases and leading zeros. No list (e.g. --no-repack): every Intel -> native.
  local xesel=""
  if [ -s "${CHURRO_XE_IDS:-}" ]; then
    local xere; xere=$({ cat "$CHURRO_XE_IDS"; tr 'A-F' 'a-f' < "$CHURRO_XE_IDS"; } | sort -u | paste -sd'|')
    xesel="setpci -s 00:02.0 -v igpudev DEVICE_ID
if [ \"\$igpu\" = \"8086\" ]; then if regexp '^0*($xere)\$' \"\$igpudev\"; then set gfx=native; else set gfx=mesa; fi; fi"
  fi
  # Vulkan for the Intel GPUs on Mesa (pre-Gen12): Mesa's hasvk for Gen7-8 (Ivy Bridge, Haswell,
  # Broadwell; IDs from gfx-mesa), else the image's own ANV, which also runs on i915 (Gen9-11).
  # Google's camera HAL and Chrome need Vulkan.
  local vksel=""
  if [ -n "$xesel" ] && [ -s "${CHURRO_HASVK_IDS:-}" ]; then
    local hre; hre=$({ tr 'A-F' 'a-f' < "$CHURRO_HASVK_IDS"; tr 'a-f' 'A-F' < "$CHURRO_HASVK_IDS"; } | sort -u | paste -sd'|')
    vksel="if [ \"\$gfx\" = mesa ]; then if regexp '^0*($hre)\$' \"\$igpudev\"; then set vk=intel_hasvk; else set vk=intel; fi; set vk=\"androidboot.churro.vulkan=\$vk\"; fi"
  fi
  cat > "$mnt/churro/grub.cfg" <<EOF
# Project Churro boot menu. Kernel cmdline = Googlebook vendor_boot cmdline + Churro additions.
set timeout=5
set default=0
source (\$root)/churro/env.cfg
probe --set=puuid --part-uuid (\$root)
set vcmd="$vcmd"

set base="\$vcmd androidboot.boot_part_uuid=\$puuid androidboot.boot_source=\$boot_source"
# debug: log on screen (fbcon) + serial, stop on errors instead of rebooting (panic=0; Android
# init's fatal errors become panics; the image's lockup watchdogs only warn), plus feature debug
# args (debug-log: boot.log on the CHURRO-LOG partition).
set dbg="console=tty0 console=ttyS1,115200 ignore_loglevel printk.devkmsg=on panic=0 androidboot.init_fatal_panic=true softlockup_panic=0 nmi_watchdog=nopanic ${CHURRO_DEBUG_ARGS:-}"
# Graphics stack from the GPUs present, appended last: a menu entry or extra_args naming one
# comes first on the cmdline and wins (Android keeps the first value of a ro. property).
# Intel iGPU (always at 00:02.0, hybrid laptops included) -> Googlebook's own stack (xe), or
# Mesa on our i915 if xe doesn't know the GPU (pre-Gen12); else an NVIDIA GPU (display
# controller class 0300/0302) -> nouveau; else software rendering.
set gfx=soft
setpci -d 10de: -v nvclass CLASS_DEVICE
if [ "\$nvclass" = "300" -o "\$nvclass" = "302" -o "\$nvclass" = "0300" -o "\$nvclass" = "0302" ]; then set gfx=nouveau; fi
setpci -s 00:02.0 -v igpu VENDOR_ID
if [ "\$igpu" = "8086" ]; then set gfx=native; fi
$xesel
set vk=""
$vksel
set gfx="androidboot.churro.gfx=\$gfx \$vk"
# A submenu opens a new GRUB context that only sees exported variables: without this, the
# "Graphics: other stacks" entries boot with an empty cmdline (no vendor args) and reboot at once.
export base dbg extra_args vk

menuentry "Googlebook OS (Churro)" {
  linux (\$root)/churro/kernel \$base \$extra_args \$gfx
  initrd (\$root)/churro/initrd.img
}
menuentry "Googlebook OS (Churro) - debug (log on screen + CHURRO-LOG/boot.log)" {
  linux (\$root)/churro/kernel \$base \$dbg \$extra_args \$gfx
  initrd (\$root)/churro/initrd.img
}
# Intel xe display: DSB poll errors at init left the panel undetected (hwc went headless) on
# Arrow Lake. Flags go last so they override the vendor cmdline's xe.enable_psr=1.
menuentry "Googlebook OS (Churro) - debug, safe display (Intel: no DSB/PSR/DC states)" {
  linux (\$root)/churro/kernel \$base \$dbg \$extra_args xe.enable_dsb=0 xe.enable_psr=0 xe.enable_dc=0 \$gfx
  initrd (\$root)/churro/initrd.img
}
menuentry "Googlebook OS (Churro) - early debug (slow firmware console, for black screens)" {
  linux (\$root)/churro/kernel \$base \$dbg earlycon=efifb \$extra_args \$gfx
  initrd (\$root)/churro/initrd.img
}
submenu "Graphics: other stacks" {
  menuentry "NVIDIA (nouveau) - debug" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=nouveau \$dbg \$extra_args
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Mesa (older Intel iris/crocus, AMD, virgl)" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=mesa \$extra_args \$vk
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Mesa software rendering (slow, any GPU)" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=soft \$extra_args
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Googlebook native (Intel Gen12+: ANGLE on ANV)" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=native \$extra_args
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Mesa - debug" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=mesa \$dbg \$extra_args \$vk
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Googlebook native - debug" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=native \$dbg \$extra_args
    initrd (\$root)/churro/initrd.img
  }
}
menuentry "UEFI firmware settings" { fwsetup }
EOF
  sync; umount "$mnt"; rmdir "$mnt"
}
