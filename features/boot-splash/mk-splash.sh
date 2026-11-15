#!/usr/bin/env bash
# Remake splash.tga (Linux: churro-splash) and splash-tab.tga (GRUB's theme, with the Tab hint)
# from docs/logo/churro-logo.svg after a logo change; both are committed, builds don't run this.
# 1600 px square black canvas; the SVG's 512-unit box 593 px wide in the middle, so the drawing
# (470 units) is 34% of the screen height once scaled to it. splash-test.sh assumes this layout.
# Needs rsvg-convert and ImageMagick.
set -euo pipefail
F="$(dirname "$(realpath "$0")")"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
rsvg-convert -w 593 -h 593 "$F/../../docs/logo/churro-logo.svg" -o "$W/logo.png"
convert -size 1600x1600 xc:black "$W/logo.png" -geometry +503+503 -composite "$W/c.png"
# top-left origin + RLE: what GRUB's tga reader and splash.c both read
convert "$W/c.png" -type TrueColor -orient TopLeft -compress RLE "$F/splash.tga"
convert "$W/c.png" -gravity north -font DejaVu-Sans -pointsize 38 -fill '#9aa0a6' \
  -annotate +0+1376 'Press Tab for boot options' -type TrueColor -orient TopLeft -compress RLE "$F/splash-tab.tga"
