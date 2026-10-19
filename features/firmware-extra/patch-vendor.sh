#!/usr/bin/env bash
# Firmware the image's own drivers ask for but the Googlebook image doesn't ship (it only carries
# what its target needs, e.g. Panther Lake GPU firmware, its own Wi-Fi). Data-driven: the
# firmware names every vendor_dlkm/system_dlkm module declares (modinfo -F firmware) + extra.txt
# (names drivers build at runtime, e.g. Intel Bluetooth) + every file WHENCE lists for a shipped
# driver, minus skip.txt, fetched from a pinned linux-firmware tag into /vendor/firmware; plus
# Intel's audio DSP firmware (sof-bin) and the Wi-Fi regulatory database, which live elsewhere. Names linux-firmware only creates when installed
# (WHENCE "Link:", e.g. a dozen NVIDIA chips sharing one 60 MB GSP image) become hardlinks to a
# single copy. The release tarball is downloaded and unpacked once (cache).
set -euo pipefail
T=$1; FW=$T/firmware; F=$(dirname "$0")
. "$(dirname "$0")/../../versions.env"   # linux-firmware, sof-bin, wireless-regdb
TAG=$CHURRO_LINUX_FIRMWARE
C=${CHURRO_CACHE:-/var/cache/churro}/linux-firmware-$TAG; mkdir -p "$C"
# the release tarball, unpacked once (thousands of files: one download beats one request each)
if [ ! -f "$C/.unpacked" ]; then
  curl -fL --retry 3 -o "$C/lf.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/firmware/linux-firmware-$TAG.tar.xz"
  tar xJf "$C/lf.tar.xz" -C "$C" --strip-components=1; rm -f "$C/lf.tar.xz"; touch "$C/.unpacked"
fi

# The modules live on vendor_dlkm/system_dlkm (other LP partitions of the same super).
M=$(mktemp -d); trap 'rm -rf "$M"' EXIT
for p in vendor_dlkm_a system_dlkm_a; do
  read -r off size < <(python3 "$CHURRO_HERE/lib/lpinfo.py" "$CHURRO_SUPER" "$p") || continue
  L=$(losetup -f --show -r -o "$off" --sizelimit "$size" "$CHURRO_SUPER")
  "$EROFS_BIN/fsck.erofs" --extract="$M/$p" "$L" >/dev/null || true
  losetup -d "$L"
done

# WHENCE links: "Link: nvidia/gb203 -> gb202" (a dir), "Link: x/a.bin -> ../y/a.bin" (a file)
declare -A LNK FIRST
while read -r a b; do LNK[$a]=$(realpath -m -s --relative-to=/ "/$(dirname "$a")/$b"); done \
  < <(sed -n 's/^Link: *\([^ ]*\) *-> *\([^ ]*\).*$/\1 \2/p' "$C/WHENCE")
# resolve <name>: the file stored in git behind a name (links on the name or any parent dir)
resolve() {
  local p=$1 pre rest n
  for n in 1 2 3 4 5 6 7 8; do
    pre=$p rest=
    while [ -z "${LNK[$pre]:-}" ] && [ "$pre" != "${pre%/*}" ]; do rest=/${pre##*/}$rest; pre=${pre%/*}; done
    [ -n "${LNK[$pre]:-}" ] || break
    p=${LNK[$pre]}$rest
  done
  echo "$p"
}
mapfile -t SKIP < <(grep -vE '^\s*(#|$)' "$F/skip.txt")
skip() { local s; for s in "${SKIP[@]}"; do case $1 in $s) return 0 ;; esac; done; return 1; }

# Names drivers build at runtime (board files, per-laptop amplifier tunings, ...) aren't in
# modinfo, but WHENCE lists every file under the driver that uses it: take all files of every
# WHENCE "Driver:" section that matches a shipped module (same name, or the module name starts
# with "<driver>_" / ends with "_<driver>", e.g. ath11k_pci, snd_hda_scodec_cs35l41).
find "$M" -name '*.ko' -printf '%f\n' | sed 's/\.ko$//' | tr - _ | sort -u > "$M/mods"
awk 'NR==FNR {m[$1]=1; next}
  /^Driver:/ { d=$2; gsub("-", "_", d); ok=(d in m); if (!ok) for (k in m) if (index(k, d "_")==1 || (length(k)>length(d) && substr(k, length(k)-length(d))=="_" d)) { ok=1; break } next }
  /^-+$/ { ok=0 }
  ok && /^(File|RawFile|Link):/ { print $2 }' "$M/mods" "$C/WHENCE" > "$M/whence-files"

{ find "$M" -name '*.ko' -exec modinfo -F firmware {} + 2>/dev/null
  cat "$M/whence-files"
  grep -vE '^\s*(#|$)' "$F/extra.txt"; } | sort -u | while read -r f; do
  case $f in *'*'*|/*|*..*) continue ;; esac          # globs / odd paths: skip
  [ -e "$FW/$f" ] && continue                         # the image already has it
  skip "$f" && continue
  r=$(resolve "$f"); skip "$r" && continue
  # linux-firmware moved some files into vendor dirs (iwlwifi-* -> intel/iwlwifi/); drivers still
  # ask for the old name, which is where it's installed. Not in the release: skipped.
  s=$C/$r; [ -f "$s" ] || s=$C/intel/iwlwifi/$r; [ -f "$s" ] || continue
  if [ -n "${FIRST[$r]:-}" ]; then mkdir -p "$(dirname "$FW/$f")"; ln "${FIRST[$r]}" "$FW/$f"
  else install -D -m 0644 -o root -g root "$s" "$FW/$f"; FIRST[$r]=$FW/$f; fi
  echo "$FW/$f"
done > "$M/added"

# Firmware outside linux-firmware: Intel audio DSP firmware + topologies (SOF, sof-bin release;
# the driver picks files by platform and codec at runtime) and the Wi-Fi regulatory database.
SOF=$CHURRO_SOF; S=${CHURRO_CACHE:-/var/cache/churro}/sof
mkdir -p "$S"; [ -s "$S/sof-bin-$SOF.tar.gz" ] || { curl -fsSL --retry 3 -o "$S/t.tmp" \
  "https://github.com/thesofproject/sof-bin/releases/download/v$SOF/sof-bin-$SOF.tar.gz"; mv "$S/t.tmp" "$S/sof-bin-$SOF.tar.gz"; }
tar xzf "$S/sof-bin-$SOF.tar.gz" -C "$M"
mkdir -p "$FW/intel"
for d in "$M/sof-bin-$SOF"/sof*; do   # merge per file, never overwrite: the image already ships sof-ipc4/ptl etc.
  (cd "$M/sof-bin-$SOF" && find "${d##*/}") | while read -r r; do
    [ -e "$FW/intel/$r" ] || [ -L "$FW/intel/$r" ] || echo "$FW/intel/$r"; done >> "$M/added"
  tar cf - -C "$M/sof-bin-$SOF" "${d##*/}" | tar xf - -C "$FW/intel" --skip-old-files --no-same-owner
done
RDB=$CHURRO_REGDB
for f in regulatory.db regulatory.db.p7s; do
  [ -e "$FW/$f" ] && continue
  [ -s "$S/$RDB-$f" ] || curl -fsSL --retry 3 -o "$S/$RDB-$f" \
    "https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git/plain/$f?h=$RDB"
  install -m 0644 "$S/$RDB-$f" "$FW/$f"; echo "$FW/$f" >> "$M/added"
done

# New files and dirs get the firmware dir's SELinux label (vendor_firmware_file).
lbl=$(getfattr --absolute-names --only-values -n security.selinux "$FW")
find "$FW" | while read -r x; do   # -h: symlinks (sof-bin) get their own label
  getfattr -h --absolute-names --only-values -n security.selinux "$x" >/dev/null 2>&1 || setfattr -h -n security.selinux -v "$lbl" "$x"
done
echo "   vendor: +$(wc -l < "$M/added") firmware files ($(tr '\n' '\0' < "$M/added" | du -cm --files0-from=- | tail -1 | cut -f1) MiB) from linux-firmware $TAG, sof-bin $SOF, wireless-regdb $RDB"
