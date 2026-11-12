#!/usr/bin/env bash
# Kernel side of audio-generic: Googlebook's module config is for one board.
# - modules.blocklist has `blocklist snd_hda_intel`: the legacy HD-audio driver never loads, so
#   machines SOF doesn't take (desktops, AMD, older Intel, QEMU) have no sound card at all;
# - modules.options forces Lenovo's codec quirk and DMIC count on SOF's generic HDA machine
#   (`hda_model=alc-2024y-chromebook dmic_num=4`): wrong pin setup on any other Realtek codec.
# Both lines go; the kernel then auto-detects like a distro (the vendor cmdline's audio
# overrides are stripped in churro.sh). Rewritten in place: keeps the files' SELinux labels.
set -euo pipefail
. "$(dirname "$0")/../../lib/note.sh"
D=$1/lib/modules
edit() { local c; grep -qE "$1" "$2" || note "audio-generic: no line matching '$1' in vendor_dlkm ${2##*/}"
         c=$(grep -vE "$1" "$2" || true); printf '%s\n' "$c" > "$2"; }
edit '^blocklist snd_hda_intel$' "$D/modules.blocklist"
edit '^options snd_sof_intel_hda_generic .*(hda_model|dmic_num)=' "$D/modules.options"
# Codec drivers must be loaded before the controller probes: it binds a driver to each codec
# right after finding it and gives up if there is none ("Cannot probe codecs"). Linux autoloads
# them from there (request_module); Android can't, and ueventd's alias load comes too late.
# Google softdeps its one codec; we preload all of them (they bind only to their own codecs;
# the generic parser catches the rest).
codecs=$(cd "$D" && ls snd-hda-codec-*.ko | sed 's/\.ko$//; s/-/_/g' | tr '\n' ' ')
for m in snd_hda_intel snd_sof_intel_hda snd_sof_intel_hda_generic; do
  echo "softdep $m pre: $codecs"; done >> "$D/modules.softdep"
echo "   vendor_dlkm: audio-generic: snd_hda_intel unblocked, Lenovo codec/DMIC options removed, $(wc -w <<< "$codecs") codec drivers preloaded"
