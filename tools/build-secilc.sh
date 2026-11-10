#!/usr/bin/env bash
# secilc (SELinux CIL compiler) for tools/check-sepolicy.sh: Ubuntu 24.04's (3.5) can't read
# Google's policy (netlink "nlmsg" extended permissions and newer policy capabilities). Built
# into tools/bin, again whenever SELINUX_VER changes (tools/bin/secilc.version).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../versions.env"; VER=$SELINUX_VER
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 -b "$VER" https://github.com/SELinuxProject/selinux.git "$T/src"
make -s -C "$T/src/libsepol/src" -j"$(nproc)" libsepol.a >/dev/null
# libsepol linked in: with the default -lsepol it loads the distro's (3.5) at run time
make -s -C "$T/src/secilc" -j"$(nproc)" secilc CFLAGS="-O2 -I$T/src/libsepol/include" \
  LDLIBS="$T/src/libsepol/src/libsepol.a" >/dev/null
! ldd "$T/src/secilc/secilc" | grep -q libsepol || { echo "build-secilc: secilc still uses the system libsepol" >&2; exit 1; }
mkdir -p "$HERE/bin"; cp "$T/src/secilc/secilc" "$HERE/bin/"; echo "$VER" > "$HERE/bin/secilc.version"
echo "secilc $VER -> $HERE/bin/secilc"
