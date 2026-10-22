# Google's public x86_64 emulator image of the same Android release (CHURRO_EMU_URL/SHA1 in
# versions.env): the platform built for generic x86-64. Donor for software KeyMint/Gatekeeper
# (security-software) and for core libraries without Panther Lake instructions (libs-generic).
# emu_part vendor|system: prints the unpacked partition's directory (downloaded/unpacked once).
emu_part() {
  local p=$1 C=${CHURRO_CACHE:-/var/cache/churro} D Z T L off size
  D=$C/emu-$p
  [ -f "$D/.done" ] && { echo "$D"; return 0; }
  mkdir -p "$C"; Z=$C/$(basename "$CHURRO_EMU_URL")
  [ -f "$Z" ] && echo "$CHURRO_EMU_SHA1  $Z" | sha1sum -c --quiet >/dev/null 2>&1 ||
    { echo "   downloading $(basename "$Z") (~2.2 GB, once)" >&2; curl -fL# -o "$Z" "$CHURRO_EMU_URL" >&2; }
  echo "$CHURRO_EMU_SHA1  $Z" | sha1sum -c --quiet >&2
  T=$(mktemp -d); rm -rf "$D"; mkdir -p "$D"
  if [ "$p" = vendor ]; then   # vendor.img: GPT, ext4 in p1
    unzip -q -o "$Z" '*/vendor.img' -d "$T"
    L=$(losetup -f --show -r -P "$(find "$T" -name vendor.img)"); sleep 1
    debugfs -R "rdump / $D" "${L}p1" >/dev/null 2>&1; losetup -d "$L"
  else                         # system.img: GPT, p2 = super with ext4 logical partitions
    unzip -q -o "$Z" '*/system.img' -d "$T"
    L=$(losetup -f --show -r -P "$(find "$T" -name system.img)"); sleep 1
    read -r off size < <(python3 "${CHURRO_HERE:?}/lib/lpinfo.py" "${L}p2" "$p")
    local P; P=$(losetup -f --show -r -o "$off" --sizelimit "$size" "${L}p2")
    debugfs -R "rdump / $D" "$P" >/dev/null 2>&1; losetup -d "$P"; losetup -d "$L"
  fi
  rm -rf "$T"; [ -n "$(ls -A "$D")" ] || { echo "emulator $p partition: unpack failed" >&2; return 1; }
  touch "$D/.done"; echo "$D"
}

# emu_same_api <image build.prop> <emulator build.prop>: 0 if both are the same Android release
# (API level, ro.[vendor.]build.version.sdk). Another release's bionic or KeyMint can match by
# export list yet differ in internal formats (system properties, linker config, HAL versions).
emu_same_api() {
  local a b
  a=$(sed -n 's/^ro\.\(vendor\.\)\{0,1\}build\.version\.sdk=//p' "$1" | head -1)
  b=$(sed -n 's/^ro\.\(vendor\.\)\{0,1\}build\.version\.sdk=//p' "$2" | head -1)
  [ -n "$a" ] && [ "$a" = "$b" ] && return 0
  echo "   emulator image is Android API ${b:-?}, this image API ${a:-?}: CHURRO_EMU_URL (versions.env) must be the same release" >&2
  return 1
}
