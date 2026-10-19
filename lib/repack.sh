# shellcheck shell=bash
# Patch logical partitions inside "super": extract EROFS -> apply overlay -> rebuild -> write back.
# Requires dm-verity off (vbmeta_disable) since the content no longer matches Google's hashtree.
EROFS_BIN=${EROFS_BIN:-$HERE/tools/bin}

# vbmeta_disable <vbmeta partition>: set flags = HASHTREE_DISABLED|VERIFICATION_DISABLED (3).
# Accepted by first-stage init because we boot with androidboot.vbmeta.device_state=unlocked.
vbmeta_disable() {
  [ "$(head -c 4 "$1")" = "AVB0" ] || { echo "not a vbmeta: $1" >&2; return 1; }
  printf '\x00\x00\x00\x03' | dd of="$1" bs=1 seek=120 conv=notrunc status=none
}

# overlay_apply <overlay dir> <tree>: add/replace files without touching existing dirs' metadata.
# Overlay files may come from a Windows checkout (777, wrong owner): normalize to Android
# defaults - root:root, 0755 dirs, 0644 files, 0755 for anything under bin/ or *.sh.
overlay_apply() {
  local ovl=$1 dst=$2 f
  (cd "$ovl" && find . -mindepth 1 -type d) | while read -r f; do
    [ -d "$dst/$f" ] || { install -d -m 0755 -o root -g root "$dst/$f"; selabel_like "$dst/$f"; }; done
  (cd "$ovl" && find . -type f) | while read -r f; do
    case $f in */bin/*|*.sh) m=0755 ;; *) m=0644 ;; esac
    install -m $m -o root -g root "$ovl/$f" "$dst/$f"; selabel_like "$dst/$f"; done
}

# selabel_like <path>: give a new file the SELinux label of an existing sibling (same type of
# entry), else of its parent dir. Host libselinux can't use Android file_contexts reliably, so
# mkfs.erofs --file-contexts would silently drop every label; we keep extracted xattrs instead.
selabel_like() {
  local p=$1 dir ref lbl
  dir=$(dirname "$p")
  if [ -d "$p" ]; then ref=$dir
  else ref=$(find "$dir" -maxdepth 1 -type f ! -path "$p" | head -1); ref=${ref:-$dir}; fi
  lbl=$(getfattr --only-values -n security.selinux "$ref" 2>/dev/null | tr -d '\0') || true
  [ -n "$lbl" ] && setfattr -n security.selinux -v "$lbl" "$p"
  return 0
}

# erofs_repack <super dev> <partition name, e.g. vendor_a> <mount point, e.g. /vendor> <feature dir>...
# For each feature dir: copy <feature>/<partition>/ over the tree, then run
# <feature>/patch-<partition>.sh <tree> if present.
erofs_repack() {
  local super=$1 name=$2 mp=$3; shift 3
  local part=${mp#/} off size T src f
  part=${part:-system}   # system is mounted at /: features use system/ and patch-system.sh
  read -r off size < <(python3 "$HERE/lib/lpinfo.py" "$super" "$name") || { echo "no LP partition $name" >&2; return 1; }
  T=$(mktemp -d /tmp/churro-repack.XXXX)
  src=$(losetup -f --show -r -o "$off" --sizelimit "$size" "$super")
  "$EROFS_BIN/fsck.erofs" --extract="$T/root" --xattrs --preserve "$src" >/dev/null
  local uuid; uuid=$("$EROFS_BIN/dump.erofs" "$src" | awk '/UUID/ {print $NF}')
  losetup -d "$src"
  for f in "$@"; do
    [ -d "$f/$part" ] && overlay_apply "$f/$part" "$T/root"
    [ -f "$f/patch-$part.sh" ] && CHURRO_SUPER=$super CHURRO_HERE=$HERE EROFS_BIN=$EROFS_BIN bash "$f/patch-$part.sh" "$T/root"
  done
  # lz4hc + 256K pclusters instead of Google's lz4 so the bigger tree still fits the old extent
  "$EROFS_BIN/mkfs.erofs" -zlz4hc,12 -C262144 -T0 -U "$uuid" --mount-point="$mp" \
     "$T/new.erofs" "$T/root" >/dev/null
  [ -n "$(getfattr --only-values -n security.selinux "$T/root" 2>/dev/null)" ] || { echo "lost SELinux labels" >&2; return 1; }
  local nsz; nsz=$(stat -c %s "$T/new.erofs")
  echo "   $name: $size -> $nsz bytes"
  if [ "$nsz" -gt "$size" ]; then
    # move the partition to free space at the end of super (rewrites all LP metadata slots)
    read -r off size < <(python3 "$HERE/lib/lpinfo.py" "$super" grow "$name" "$nsz") || { rm -rf "$T"; return 1; }
    echo "   $name relocated in super: offset $off, extent $size"
  fi
  dd if="$T/new.erofs" of="$super" bs=1M seek="$off" oflag=seek_bytes conv=notrunc,fsync status=none
  rm -rf "$T"
}
