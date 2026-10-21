#!/usr/bin/env bash
# timberslide copies the ChromeOS EC's console log to logcat and /data/misc/timberslide (read
# only, never writes to the EC). PCs have no ChromeOS EC: it exits at once and init restarts it
# every ~5 s; as an updatable process each crash also runs flags_health_check (resets
# server-configurable flags) and makes apexd try reverts. Its rc goes; the binary stays, unused.
set -euo pipefail
R=$1/system/etc/init/timberslide.rc
[ -f "$R" ] || { echo "   system: no timberslide.rc (nothing to do)"; exit 0; }
rm -f "$R"
echo "   system: timberslide (ChromeOS EC log daemon) disabled"
