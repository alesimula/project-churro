#!/usr/bin/env bash
# timberslide copies the ChromeOS EC's console log to logcat and /data/misc/timberslide (read
# only, never writes to the EC). PCs have no ChromeOS EC: it exits at once and init restarts it
# every ~5 s; as an updatable process each crash also runs flags_health_check (resets
# server-configurable flags) and makes apexd try reverts. Its rc goes; the binary stays, unused.
#
# update_engine applies Google's OTAs. Delta OTAs fail (our partitions differ), so Google serves a
# full one (~3 GB into userdata/super) for a slot our GRUB never boots. Its rc goes, so every
# install attempt fails before downloading.
set -euo pipefail
for s in timberslide update_engine; do
  R=$1/system/etc/init/$s.rc
  [ -f "$R" ] || { echo "   system: no $s.rc (nothing to do)"; continue; }
  rm -f "$R"
  echo "   system: $s disabled"
done
