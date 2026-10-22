# Host packages Churro needs (Debian/Ubuntu names). deps_ensure installs the missing ones in one go
# when run as root; otherwise it names them (with the apt command) and stops. On other distros it
# only lists them (install your distro's equivalents).
#   image: gdisk dosfstools parted grub-* cpio attr kmod openssl curl python3 binutils
#   kernel config/vmlinux extraction: lz4 zstd xz-utils bzip2 (extract-ikconfig fails with
#     "Cannot find kernel config" when the kernel's decompressor is missing)
#   setup-no-ota: default-jre-headless (keytool + the build-tools apksigner)
#   builds (kernel, pahole, erofs-utils, Mesa, static helpers): the rest
CHURRO_PKGS="gdisk dosfstools parted grub-common grub-efi-amd64-bin cpio attr kmod openssl curl git unzip
  python3 python3-venv binutils lz4 zstd xz-utils bzip2 build-essential flex bison bc rsync pkg-config
  cmake ninja-build libssl-dev libelf-dev libdw-dev zlib1g-dev autoconf automake libtool liblz4-dev
  uuid-dev libselinux1-dev default-jre-headless"
# tools/updater (needs no root): sgdisk, curl, unzip, python3, plus dump.erofs >= 1.8 for
# buildinfo.sh (`--cat`; Ubuntu 24.04 ships 1.7.1), built into tools/bin with these packages.
UPDATER_PKGS="gdisk curl unzip python3"
EROFS_BUILD_PKGS="git build-essential autoconf automake libtool pkg-config liblz4-dev uuid-dev
  libselinux1-dev zlib1g-dev"
DEPS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# deps_ensure [updater]: no argument = everything churro.sh and tools/prepare.sh need;
# "updater" = only what tools/updater needs. Messages go to stderr (callers print eval-able stdout).
# shellcheck disable=SC2086  # $pkgs/$miss are word lists on purpose
deps_ensure() {
  local p miss="" pkgs=$CHURRO_PKGS b=$DEPS_ROOT/tools/bin erofs=1
  [ -x "$b/fsck.erofs" ] && [ -x "$b/dump.erofs" ] && [ -x "$b/mkfs.erofs" ] && erofs=0
  if [ "${1:-}" = updater ]; then
    pkgs=$UPDATER_PKGS
    [ -n "${EROFS_BIN:-}" ] && [ -x "$EROFS_BIN/dump.erofs" ] && erofs=0
    [ "$erofs" = 0 ] || pkgs="$pkgs $EROFS_BUILD_PKGS"
  fi
  if ! command -v apt-get >/dev/null || ! command -v dpkg-query >/dev/null; then
    echo ">> not Debian/Ubuntu: make sure the equivalents of these are installed:" $pkgs >&2
  else
    for p in $pkgs; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || miss="$miss $p"; done
  fi
  if [ -n "$miss" ]; then
    [ "$(id -u)" = 0 ] || { echo "churro: missing packages:$miss" >&2
                            echo "  install them with: sudo apt-get install$miss" >&2; exit 1; }
    echo ">> installing missing packages:$miss" >&2
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $miss >/dev/null
  fi
  # erofs-utils that can extract SELinux xattrs isn't packaged (Ubuntu 24.04 has 1.7.1): built once
  # into tools/bin, which is not in git (a fresh clone or zip doesn't have it).
  [ "$erofs" = 1 ] || return 0
  echo ">> building erofs-utils into tools/bin (once)" >&2
  bash "$DEPS_ROOT/tools/build-erofs-utils.sh" >&2
}
