#!/usr/bin/env bash
# Self-check for churro-density with a stub churro-drm (any Linux shell): the reference panel keeps
# 240, a 1366x768 13.3" panel gets 160, no size falls back to resolution, the built-in panel wins.
set -e
S="$(dirname "$(realpath "$0")")/churro-density"; W=$(mktemp -d); trap 'rm -rf $W' EXIT
mkdir -p $W/bin; printf '#!/bin/sh\necho "setprop $*" >> %s/props\n' $W > $W/bin/setprop; chmod +x $W/bin/setprop
check() {  # check <want> <name> <churro-drm lines...>
  want=$1 name=$2; shift 2; printf '%s\n' "$@" > $W/drm.out; : > $W/props
  PATH=$W/bin:$PATH CHURRO_DRM="cat $W/drm.out" ${SH:-sh} "$S" > $W/log
  got=$(sed -n 's/^setprop vendor.audio.churro.density //p' $W/props)
  [ "$got" = "$want" ] || { echo "FAIL $name: got '$got', want '$want' ($(cat $W/log))"; exit 1; }; echo "ok $name ($got)"
}
check 240 "reference 2880x1800 15.3in"   "panel 2880 1800 330 206 card0-eDP-1"
check 160 "1366x768 13.3in"              "panel 1366 768 293 165 card0-eDP-1"
check 176 "4K 27in monitor"              "ext 3840 2160 597 336 card0-HDMI-A-1"
check 204 "MSI 2560x1600 16in"           "panel 2560 1600 345 215 card0-eDP-1"
check 160 "HP 24f 1080p monitor"         "ext 1920 1080 527 296 card0-HDMI-A-1"
check 160 "no size, 1024x600 (VM)"       "ext 1024 600 0 0 card0-Virtual-1"
check 204 "panel wins over monitor"      "ext 1920 1080 510 287 card0-HDMI-A-1" "panel 2560 1600 345 215 card0-eDP-1"
check 240 "real GPU wins over simpledrm" "fw 2880 1800 0 0 card0-Unknown-1" "panel 2880 1800 330 206 card1-eDP-1"
check 160 "simpledrm only, 1024x600"     "fw 1024 600 0 0 card0-Unknown-1"
check ""  "no screen: nothing set"       ""
# render node of an amdgpu screen (gfx-amd.rc -> minigbm), none for other drivers
mkdir -p $W/sys/class/drm/card1/device/drm/renderD129 $W/sys/class/drm/card0/device/drm/renderD128 $W/drv/amdgpu $W/drv/i915
ln -s $W/drv/amdgpu $W/sys/class/drm/card1/device/driver; ln -s $W/drv/i915 $W/sys/class/drm/card0/device/driver
render() {  # render <want> <name> <churro-drm line>
  printf '%s\n' "$3" > $W/drm.out; : > $W/props
  PATH=$W/bin:$PATH CHURRO_DRM="cat $W/drm.out" CHURRO_SYS=$W/sys ${SH:-sh} "$S" 2>/dev/null
  got=$(sed -n 's/^setprop vendor.audio.churro.render //p' $W/props)
  [ "$got" = "$1" ] || { echo "FAIL $2: got '$got', want '$1'"; exit 1; }; echo "ok $2 ($got)"
}
render 129 "amdgpu panel: its render node" "panel 1920 1080 344 194 card1-eDP-1"
render ""  "i915 panel: none"              "panel 1920 1080 344 194 card0-eDP-1"
