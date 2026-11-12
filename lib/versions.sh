# Which folder a version gets (docs/09-version-support.md): kernel patches by kernel series and
# build, minigbm patches by Android API level and image build, Mesa patches by Mesa release.
# version_dir <root> <series> <number>
#   <root>'s folders are named <series> (from that series' first version on) or <series>-<N>
#   (from number N on; -ab<N> for kernel builds): 6.18, 6.18-ab17000000, api37, api37-16900000,
#   26.2, 26.2-5. Each holds a full set, not a layer. Prints the newest folder that is not newer
#   than the version: its own series with the highest N <= <number>, else the newest older
#   series (said on stderr: its patches may not apply). Fails when there is none.
version_dir() {
  local root=$1 ser=$2 num=$3 pre=${2%%[0-9]*} d s n bs="" bn=-1 best=""
  [[ $num =~ ^[0-9]+$ ]] || num=0
  for d in "$root"/*/; do
    d=${d%/}; s=${d##*/}; n=0
    if [[ $s =~ ^(.+)-[a-z]*([0-9]+)$ ]]; then s=${BASH_REMATCH[1]}; n=${BASH_REMATCH[2]}; fi
    [[ $s =~ ^${pre}[0-9]+(\.[0-9]+)*$ ]] || continue                                # not a version folder
    [ "$(printf '%s\n%s\n' "$s" "$ser" | sort -V | tail -1)" = "$ser" ] || continue   # a newer series
    if [ "$s" = "$ser" ] && [ "$n" -gt "$num" ]; then continue; fi                    # a later version of it
    if [ -n "$bs" ]; then                                                             # better than the best so far?
      if [ "$s" = "$bs" ]; then if [ "$n" -le "$bn" ]; then continue; fi
      elif [ "$(printf '%s\n%s\n' "$s" "$bs" | sort -V | tail -1)" = "$bs" ]; then continue; fi
    fi
    bs=$s bn=$n best=$d
  done
  [ -n "$best" ] || { echo "$root has no folder for $ser or older: copy the newest folder to $root/$ser and rebase its patches (docs/09-version-support.md)" >&2; return 1; }
  [ "$bs" = "$ser" ] || echo ">> $root has no folder for $ser: using ${best##*/}" >&2
  echo "$best"
}
# kernel_patch_dir <kmod/patches> <kernel release, e.g. 6.18.21-android17-5-g0e2640c903c1-ab16560873>
kernel_patch_dir() { version_dir "$1" "$(cut -d. -f1,2 <<<"$2")" "${2##*-ab}"; }
