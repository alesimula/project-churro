#!/usr/bin/env bash
# Distro erofs-utils (Ubuntu 24.04: 1.7.1) can't extract xattrs; build a newer one into tools/bin.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../versions.env"; VER=$EROFS_VER
command -v autoreconf >/dev/null || apt-get install -y -qq autoconf automake libtool pkg-config liblz4-dev uuid-dev libselinux1-dev zlib1g-dev >/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 -b "$VER" https://github.com/erofs/erofs-utils.git "$T/src"
cd "$T/src" && ./autogen.sh >/dev/null 2>&1 && ./configure -q --enable-lz4 --with-selinux --disable-fuse >/dev/null && make -s -j"$(nproc)" >/dev/null
mkdir -p "$HERE/bin"; cp mkfs/mkfs.erofs fsck/fsck.erofs dump/dump.erofs "$HERE/bin/"
"$HERE/bin/mkfs.erofs" --version 2>&1 | head -1
