#!/usr/bin/env bash
# Project Churro - make a Googlebook OS recovery image bootable on generic UEFI PCs.
# Usage: sudo ./churro.sh auto  <recovery.bin> <out.img> [--gfx auto|native|nouveau|mesa|soft] [--packs virt,gpu,storage,wifi]
#        sudo ./churro.sh build <recovery.bin> <out.img> [--kernel dir] [--modules <pack dir>]...
#                               [--features a,b] [--boot-source external|internal]
#        sudo ./churro.sh install <churro.img> <disk>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

# NPU (Intel "VPU" AI accelerator) driver. The image only ships Panther Lake NPU firmware; on
# other Intel chips (e.g. Arrow Lake) intel_vpu fails to load it and the machine freezes during
# boot. true = let it load (only for Panther Lake-class machines).
CHURRO_NPU=${CHURRO_NPU:-false}
. "$HERE/lib/bootimg.sh"; . "$HERE/lib/bootconfig.sh"; . "$HERE/lib/esp.sh"; . "$HERE/lib/ramdisk.sh"; . "$HERE/lib/repack.sh"
. "$HERE/lib/deps.sh"

die() { echo "churro: $*" >&2; exit 1; }
log() { echo ">> $*"; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing tool: $c"; done; }

# TMPDIRS: work dirs under /tmp (build, repack), removed also when a step fails
LOOP="" TMPDIRS=""
cleanup() { [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null; [ -z "$TMPDIRS" ] || rm -rf --one-file-system $TMPDIRS; true; }
trap cleanup EXIT

# Partition by GPT label (labels are stable across Googlebook images, numbers might not be).
part() { local n; n=$(sgdisk -p "$LOOP" | awk -v l="$1" '$NF == l {print $1; exit}'); [ -n "$n" ] || die "no partition $1"; echo "${LOOP}p$n"; }

# pinfo <disk|image> <n>: "first last typeGUID uniqueGUID attrs name" of partition n
pinfo() { sgdisk -i "$2" "$1" | awk -F': ' '/First sector/ {split($2,a," "); f=a[1]} /Last sector/ {split($2,a," "); l=a[1]}
  /GUID code/ {split($2,a," "); t=a[1]} /unique GUID/ {u=$2} /Attribute flags/ {at=$2} /Partition name/ {n=$2; gsub("\x27","",n)}
  END {print f, l, t, u, at, n}'; }
# pmove <disk|image> <n> <first> <last>: re-create partition n at first..last, same type/GUID/attrs/name
pmove() { local t u at nm; read -r _ _ t u at nm < <(pinfo "$1" "$2")
  sgdisk -d "$2" -n "$2:$3:$4" -t "$2:$t" -u "$2:$u" -A "$2:=:$at" -c "$2:$nm" "$1" >/dev/null; }

# userdata_last <disk|image>: recovery images end with ota_recovery_b *after* userdata (4 GiB), so
# userdata can't grow. Move whatever follows it into the start of userdata's area (userdata is
# formatted by Android on first boot, nothing to keep) and start userdata after it.
userdata_last() {
  local d=$1 un us ue ut uu ua unm after n s e
  un=$(sgdisk -p "$d" | awk '$NF == "userdata" {print $1}'); [ -n "$un" ] || die "no userdata partition"
  read -r us ue ut uu ua unm < <(pinfo "$d" "$un")
  after=$(sgdisk -p "$d" | awk -v ue="$ue" '$1 ~ /^[0-9]+$/ && $2 > ue {print $1}')
  [ -n "$after" ] || return 0
  sgdisk -d "$un" "$d" >/dev/null   # free its range for the moved partitions, re-created below
  for n in $after; do
    read -r s e _ < <(pinfo "$d" "$n")
    [ $((e - s + 1)) -lt $((ue - us + 1)) ] || die "partition $n doesn't fit in userdata's space"
    log "moving partition $n before userdata"
    dd if="$d" of="$d" bs=1M iflag=skip_bytes,count_bytes oflag=seek_bytes conv=notrunc status=none \
       skip=$((s * 512)) seek=$((us * 512)) count=$(((e - s + 1) * 512))
    pmove "$d" "$n" "$us" $((us + e - s)); us=$((us + e - s + 1))
  done
  sgdisk -n "$un:$us:$ue" -t "$un:$ut" -u "$un:$uu" -A "$un:=:$ua" -c "$un:$unm" "$d" >/dev/null
}

# grow_userdata <disk|image>: stretch the (last) userdata partition to the end of the disk
grow_userdata() { local un us; sgdisk -e "$1" >/dev/null
  un=$(sgdisk -p "$1" | awk '$NF == "userdata" {print $1}'); read -r us _ < <(pinfo "$1" "$un")
  pmove "$1" "$un" "$us" 0; }

cmd_build() {
  local in=$1 out=$2; shift 2
  local packs=() bsrc=external feats=security-software,firmware-lockdown repack=1 kdir="" dsize=0 vexemu=1
  while [ $# -gt 0 ]; do case $1 in
    --modules) packs+=("$2"); shift 2 ;;
    --data-size) dsize=$2; shift 2 ;;   # GiB for userdata (image grows; 0 = keep the image's 4 GiB)
    --features) feats=$2; shift 2 ;;
    --no-repack) repack=0; shift ;;     # dev: partitions already patched, only redo boot files
    --boot-source) bsrc=$2; shift 2 ;;
    --kernel) kdir=$2; shift 2 ;;      # Churro kernel dir from kmod/build-kernel.sh (kernel, kernel.release)
    --vexemu) vexemu=$2; shift 2 ;;
    *) die "unknown option $1" ;; esac; done
  need losetup sgdisk mkfs.vfat grub-mkstandalone cpio lz4 od
  [ "$(id -u)" = 0 ] || die "run as root"

  if [ "$(realpath "$in")" != "$(realpath -m "$out")" ]; then
    log "copying $in -> $out (sparse)"; cp --sparse=always "$in" "$out"
  fi
  # userdata: Android 17 + Google apps fill the image's 4 GiB during the first boot (ENOSPC ->
  # system_server crash loop -> RescueParty shutdown). Make it last, then grow it to $dsize GiB.
  userdata_last "$out"
  if [ "$dsize" -gt 0 ]; then
    local un us ue cur; un=$(sgdisk -p "$out" | awk '$NF == "userdata" {print $1}'); read -r us ue _ < <(pinfo "$out" "$un")
    cur=$(((ue - us + 1) * 512)); if [ "$cur" -lt $((dsize << 30)) ]; then
      log "userdata: $((cur >> 20)) MiB -> $dsize GiB"
      truncate -s +$(((dsize << 30) - cur)) "$out"; grow_userdata "$out"; fi
  fi
  LOOP=$(losetup -f --show -P "$out"); udevadm settle 2>/dev/null || sleep 1
  local W; W=$(mktemp -d /tmp/churro.XXXX); TMPDIRS="$TMPDIRS $W"

  log "extracting boot images (slot _a)"
  bootimg_extract "$(part boot_a)" "$W/boot"
  bootimg_extract "$(part init_boot_a)" "$W/init_boot"
  vendorboot_extract "$(part vendor_boot_a)" "$W/vboot"
  ls "$W/vboot"

  local fdirs=() f p mp
  for f in ${feats//,/ }; do [ -d "$HERE/features/$f" ] || die "unknown feature: $f"; fdirs+=("$HERE/features/$f"); done
  if [ "$repack" = 1 ] && [ ${#fdirs[@]} -gt 0 ]; then
    log "applying features: $feats (dm-verity off)"
    vbmeta_disable "$(part vbmeta_a)"
    export CHURRO_KERNEL=$kdir   # for features adding our kernel's modules (gpu-nouveau)
    export CHURRO_XE_IDS=$W/xe-ids   # drivers-extra: GPU IDs the image's xe binds -> boot menu
    export CHURRO_HASVK_IDS=$W/hasvk-ids   # gfx-mesa: Intel Gen7-8 GPU IDs (Vulkan: hasvk) -> boot menu
    # vendor_dlkm first: firmware-extra (a vendor feature) reads the module list from it
    for p in vendor_dlkm vendor system system_ext product odm; do
      mp=/$p; [ "$p" = system ] && mp=/   # system-as-root
      for f in "${fdirs[@]}"; do
        if [ -d "$f/$p" ] || [ -f "$f/patch-$p.sh" ]; then erofs_repack "$(part super)" "${p}_a" "$mp" "${fdirs[@]}"; break; fi
      done
    done
  fi

  log "building Churro ramdisk"
  ramdisk_build "$W" "${packs[@]}"
  for f in "${fdirs[@]}"; do [ -f "$f/build-ramdisk.sh" ] && bash "$f/build-ramdisk.sh" "$W/cr"; done
  ramdisk_pack "$W"

  log "writing bootconfig + initrd"
  local vbc; vbc=$(cat "$W/vboot/bootconfig")
  cat > "$W/bootconfig.txt" <<EOF
$vbc
androidboot.slot_suffix=_a
androidboot.force_normal_boot=1
androidboot.verifiedbootstate=orange
androidboot.vbmeta.device_state=unlocked
androidboot.veritymode=enforcing
androidboot.serialno=CHURRO$(od -An -tx1 -N4 /dev/urandom | tr -d ' ')
androidboot.bootloader=churro-grub
churro.vexemu=$vexemu
EOF
  for f in "${fdirs[@]}"; do [ -f "$f/bootconfig" ] && cat "$f/bootconfig" >> "$W/bootconfig.txt"; done
  bootconfig_pack "$W/bootconfig.txt" "$W/bootconfig.bin"
  # Boot v4 order: vendor ramdisks (platform, dlkm), generic ramdisk, then extras, bootconfig last.
  cat "$W"/vboot/ramdisk_*_1_* "$W"/vboot/ramdisk_*_3_* "$W/init_boot/ramdisk" "$W/churro.cpio" \
      "$W/bootconfig.bin" > "$W/initrd.img"
  if [ -n "$kdir" ]; then
    # must carry the GKI release string, or none of the image's prebuilt modules will load
    local want; want=$(strings "$W/boot/kernel" 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+-android[^ ]*' || true)
    [ -z "$want" ] || [ "$want" = "$(cat "$kdir/kernel.release")" ] || log "warning: Churro kernel $(cat "$kdir/kernel.release") != image kernel $want"
    log "using Churro kernel $(cat "$kdir/kernel.release")"
    cp "$kdir/kernel" "$W/kernel"
  else
    cp "$W/boot/kernel" "$W/kernel"
  fi

  # features may add kernel cmdline args (e.g. no pKVM when the security VM isn't used)
  local fargs=""
  for f in "${fdirs[@]}"; do [ -f "$f/cmdline" ] && fargs="$fargs $(grep -vE '^\s*(#|$)' "$f/cmdline" | tr '\n' ' ')"; done
  export CHURRO_EXTRA_ARGS="$(echo $fargs ${CHURRO_EXTRA_ARGS:-})"
  fargs=""   # ...and args for the "debug" boot entries only
  for f in "${fdirs[@]}"; do [ -f "$f/cmdline-debug" ] && fargs="$fargs $(grep -vE '^\s*(#|$)' "$f/cmdline-debug" | tr '\n' ' ')"; done
  export CHURRO_DEBUG_ARGS="$(echo $fargs)"

  # Slot state: the boot HAL keeps ChromeOS-style slot flags in the vbmeta_a/_b GPT attributes
  # (bits 48-51 priority, 52-55 tries, 56 successful). Recovery images ship slot B marked and A
  # not, but we boot A: unmarked, vold runs *every* boot as an unfinished update (checkpoint,
  # dm-bow on /data), which fills a small /data and panics. Mark A active + successful, clear B.
  local va vb b; va=$(part vbmeta_a); va=${va##*p}; vb=$(part vbmeta_b); vb=${vb##*p}
  for b in 48 49 50 51 52 53 54 55 56; do sgdisk -A "$vb:clear:$b" "$LOOP" >/dev/null; done
  for b in 48 49 50 51 56; do sgdisk -A "$va:set:$b" "$LOOP" >/dev/null; done

  # Log partition: the image's KERN-A (512 MiB, unused legacy ChromeOS kernel slot, all zeros)
  # becomes a FAT32 "basic data" partition, so Windows shows it as a drive (the ESP is hidden).
  local ln; ln=$(sgdisk -p "$LOOP" | awk '$NF == "KERN-A" || $NF == "CHURRO-LOG" {print $1; exit}')
  if [ -n "$ln" ]; then
    log "log partition: p$ln -> CHURRO-LOG (FAT32)"
    sgdisk -t "$ln:0700" -c "$ln:CHURRO-LOG" "$LOOP" >/dev/null
    mkfs.vfat -F 32 -n CHURRO-LOG "${LOOP}p$ln" >/dev/null
    # Fixed-size log files, pre-filled with blank lines: the boot logger only overwrites them in
    # place, so the FAT/directory never change at boot and a power cut can't corrupt them.
    local lm; lm=$(mktemp -d); mount "${LOOP}p$ln" "$lm"
    head -c $((64 << 20)) /dev/zero | tr '\0' '\n' > "$lm/boot.log"
    for f in boot.prev.log logcat.log logcat.prev.log; do cp "$lm/boot.log" "$lm/$f"; done
    umount "$lm"; rmdir "$lm"
  fi

  # Vendor cmdline, made safe for a non-Googlebook PC (!! SAFETY-CRITICAL, keep it this way !!):
  # - BIOS flash read-only: drop spi-intel.writeable=1 / ignore_protection_status=1 and blacklist
  #   the SPI flash drivers outright (Googlebooks flash their own firmware from Android);
  # - TPM drivers blacklisted: the image's gscutil/check_tpm_clear send Google-security-chip
  #   commands to /dev/tpm0 at every boot. On a PC that is the TPM Windows/BitLocker depends on.
  #   Churro uses software security, nothing here needs the TPM;
  # - NPU driver blocked unless CHURRO_NPU=true (see top);
  # - no crash dumps into UEFI NVRAM: the GKI kernel registers efi_pstore, which writes the kernel
  #   log into EFI variables on every panic (and the debug entries turn init crashes into panics).
  #   Filling a PC's NVRAM can make its firmware unbootable.
  # - IOMMU passthrough for internal devices: Google's iwlmvm (the Wi-Fi driver for AX201/Qu-class
  #   cards; Googlebooks use iwlmld) unmaps RX buffers the IOMMU never mapped -> a WARN per packet,
  #   firmware crashes, Wi-Fi stalls (VivoBook 15, docs/02). Distro-normal; ports the firmware marks
  #   external (Thunderbolt/USB4) stay translated, the iGPU already was (igfx_off), pKVM is off.
  # module_blacklist is a single kernel parameter (the last one wins), so extend the vendor's.
  local vcmd blk=spi_intel,spi_intel_pci,tpm,tpm_tis,tpm_tis_core,tpm_crb,tpm_tis_spi,tpm_tis_i2c_cr50
  [ "$CHURRO_NPU" = true ] || blk="$blk,intel_vpu"
  vcmd=$(sed -E 's/ ?spi-intel\.(writeable|ignore_protection_status)=[^ ]*//g' "$W/vboot/cmdline")
  # Audio: the board forces SOF on every Intel HD-audio controller (dsp_driver=3), IPC4 and its
  # SoundWire links / topology NHLT. Generic: kernel defaults, i.e. auto-detect like distros
  # (SOF where DMICs/SoundWire need it, else snd_hda_intel; IPC version per platform).
  vcmd=$(printf '%s' "$vcmd" | sed -E 's/ ?(snd_intel_dspcfg\.dsp_driver|snd_sof_pci\.ipc_type|snd_intel_sdw_acpi\.sdw_link_mask|snd_sof_intel_hda_common\.sof_use_tplg_nhlt)=[^ ]*//g')
  case $vcmd in
    *module_blacklist=*) vcmd=$(printf '%s' "$vcmd" | sed -E "s/module_blacklist=([^ ]*)/module_blacklist=\1,$blk/") ;;
    *) vcmd="$vcmd module_blacklist=$blk" ;;
  esac
  vcmd="$vcmd efi_pstore.pstore_disable=1 iommu.passthrough=1"
  log "kernel cmdline: flash read-only, no TPM, no UEFI crash dumps, IOMMU passthrough, blacklisted: $blk"

  log "populating EFI-SYSTEM"
  esp_build "$(part EFI-SYSTEM)" "$W" "$vcmd" "$bsrc"
  rm -rf "$W"
  log "done: $out"
}

# install <churro.img> <target disk>: the image already has the Googlebook *installed* layout
# (same as partition-script.sh writes), so: copy it, move the backup GPT to the end of the disk,
# stretch userdata (partition 1, placed last) over the free space, mark the ESP boot as internal.
# Android formats userdata/metadata itself on first boot ("formattable").
cmd_install() {
  local img=$1 dst=$2
  need sgdisk dd partprobe
  [ "$(id -u)" = 0 ] || die "run as root"
  [ -b "$dst" ] || die "$dst is not a block device"
  [ "$(cat "/sys/block/$(basename "$dst")/removable" 2>/dev/null || echo 0)" = 0 ] || log "note: $dst is removable"
  local isz dsz; isz=$(stat -c %s "$img"); dsz=$(blockdev --getsize64 "$dst")
  [ "$dsz" -ge "$isz" ] || die "target too small ($dsz < $isz bytes)"
  log "this ERASES $dst ($((dsz / 1024 / 1024 / 1024)) GiB). Type YES to continue:"; read -r a; [ "$a" = YES ] || die "aborted"
  log "writing image"; dd if="$img" of="$dst" bs=4M conv=fsync,sparse status=progress
  log "growing userdata to the end of the disk"
  userdata_last "$dst"; grow_userdata "$dst"
  partprobe "$dst" 2>/dev/null || blockdev --rereadpt "$dst" || true; sleep 2
  local espn esp mnt; espn=$(sgdisk -p "$dst" | awk '$NF == "EFI-SYSTEM" {print $1}')
  case $dst in *[0-9]) esp=${dst}p$espn ;; *) esp=$dst$espn ;; esac   # nvme0n1p12 vs sda12
  mnt=$(mktemp -d); mount "$esp" "$mnt"
  sed -i 's/^set boot_source=.*/set boot_source=internal/' "$mnt/churro/env.cfg"; umount "$mnt"; rmdir "$mnt"
  log "done. Reboot, pick the disk in the UEFI boot menu (Secure Boot off)."
}

# auto <in.bin> <out.img> [--gfx auto|native|nouveau|mesa|soft] [--kernel-profile generic]:
# prepare everything (tools/prepare.sh) and build with the recommended defaults.
# --gfx auto (default): the boot menu picks the graphics stack from the GPUs it finds (esp.sh).
cmd_auto() {
  local in=$1 out=$2; shift 2
  local gfx=auto kprof=generic packs=virt,gpu,storage xfeat="" dsize=12 vexemu=1
  while [ $# -gt 0 ]; do case $1 in
    --gfx) gfx=$2; shift 2 ;; --kernel-profile) kprof=$2; shift 2 ;;
    --data-size) dsize=$2; shift 2 ;;   # userdata GiB (default 12: image ~26 GiB, needs a 32 GB stick)
    --packs) packs=$2; shift 2 ;;   # module packs from prepare.sh: virt,gpu,storage[,wifi]
    --extra-features) xfeat=,$2; shift 2 ;;   # extra features for test builds
    --vexemu) vexemu=$2; shift 2 ;;
    *) die "unknown option $1" ;; esac; done
  bash "$HERE/tools/prepare.sh" "$in" "$kprof"
  local envf; envf=$(ls -t "${CHURRO_CACHE:-/var/cache/churro}"/prepared-*.env | head -1)
  # shellcheck disable=SC1090
  . "$envf"; export CHURRO_MESA CHURRO_MESA_SYSROOT
  local margs=() p; for p in ${packs//,/ }; do
    [ "$p" != i915 ] || die "the i915 pack is retired (it broke xe on Gen12+): i915 now comes with drivers-extra and only loads on Intel GPUs xe doesn't drive"
    [ -d "$CHURRO_PACK_DIR/$p" ] || die "no module pack '$p' in $CHURRO_PACK_DIR"; margs+=(--modules "$CHURRO_PACK_DIR/$p"); done
  [ "$gfx" = auto ] || CHURRO_EXTRA_ARGS="androidboot.churro.gfx=$gfx ${CHURRO_EXTRA_ARGS:-}"
  cmd_build "$in" "$out" --kernel "$CHURRO_KERNEL" --data-size "$dsize" --vexemu "$vexemu" --features "security-software,firmware-lockdown,firmware-extra,gfx-mesa,gfx-minigbm,gpu-nouveau,crypto-generic,drivers-extra,audio-generic,debug-log$xfeat" "${margs[@]}"
}

case ${1:-} in auto|build|install) deps_ensure ;; esac
case ${1:-} in
  auto) shift; [ $# -ge 2 ] || die "usage: churro.sh auto <in.bin> <out.img> [--gfx auto|native|nouveau|mesa|soft]"; cmd_auto "$@" ;;
  build) shift; [ $# -ge 2 ] || die "usage: churro.sh build <in.bin> <out.img> [opts]"; cmd_build "$@" ;;
  install) shift; [ $# -eq 2 ] || die "usage: churro.sh install <churro.img> <disk, e.g. /dev/nvme0n1>"; cmd_install "$@" ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
