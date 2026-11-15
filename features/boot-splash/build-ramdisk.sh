#!/usr/bin/env bash
# Put the boot splash into the Churro ramdisk: /churro/splash (static: runs before bionic exists)
# and the picture it draws, /churro/splash.tga.
set -euo pipefail
R=$1 F="$(dirname "$0")"; mkdir -p "$R/churro"
${CC:-cc} -static -O2 -s -Wall -o "$R/churro/splash" "$F/splash.c"
chmod 0750 "$R/churro/splash"
install -m 0644 "$F/splash.tga" "$R/churro/splash.tga"
