#!/usr/bin/env bash
# The vendor partition's own libz (see patch-system.sh), from the emulator's vendor partition.
set -euo pipefail
. "$(dirname "$0")/../../versions.env"
. "$(dirname "$0")/../../lib/emu-image.sh"
. "$(dirname "$0")/swap.sh"
E=$(emu_part vendor)
emu_same_api "$1/build.prop" "$E/build.prop" || { echo "   vendor/lib64/libz.so: kept the image's"; exit 0; }
swap_group "vendor/lib64/libz.so" "$1" "$E" lib64/libz.so
