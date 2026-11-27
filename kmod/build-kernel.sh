#!/usr/bin/env bash
# Build a "Churro kernel": Google's own GKI source at the image's exact commit, with the image's
# own config, plus extra drivers and without KMI symbol trimming. Same release string, same
# CRCs (gendwarfksyms over identical types) -> the image's vendor_dlkm/system_dlkm modules keep
# loading, but we can now add drivers the stock GKI can't take as modules (i915, simpledrm, ahci...).
#
# Usage: kmod/build-kernel.sh <ack src> <clang dir> <rust dir> <bindgen dir> <ikconfig> <kernel release> <profile> <out dir>
#   profile = kmod/profiles/<name>.conf with:  Y="SYSFB_SIMPLEFB ..."  M="DRM_I915 ..."  N="..."
set -euo pipefail
# sort/join/comm must agree on one collation: with en_US.UTF-8, sort output is "unsorted" for
# join, which exits 1 and (pipefail + 2>/dev/null) silently aborts the build
export LC_ALL=C
SRC=$1 CLANG=$2 RUST=$3 BINDGEN=$4 CFG=$5 REL=$6 PROF=$7 OUT=$8
HERE=$(cd "$(dirname "$0")" && pwd)
# the patch folder for this kernel (series + build number in $REL) and its series.env
# (ARCH_LINUX_CONFIG_TAG, used by the profile): docs/09-version-support.md
. "$HERE/../lib/versions.sh"; PD=$(kernel_patch_dir "$HERE/patches" "$REL")
. "$PD/series.env"; . "$HERE/../versions.env"
Y="" M="" N=""; . "$HERE/profiles/$PROF.conf"
export PATH="$CLANG/bin:$RUST/bin:$BINDGEN:$PATH"
# bindgen must use the Android clang's libclang, not a distro one (unknown -W options otherwise)
export LIBCLANG_PATH="$CLANG/lib"
O=$SRC/out-kernel-$PROF; mkdir -p "$O"
# $PD/*.patch: small built-in fixes (no exported types touched -> CRCs unchanged).
# Applied copies are recorded in $SRC/.churro-applied: a patch that was edited or deleted since
# is reversed first, so the cached source tree always matches the patch folder. A patch the
# source already contains (Google merged the fix: it applies in reverse) is skipped.
A=$SRC/.churro-applied; mkdir -p "$A"
for a in "$A"/*.patch; do
  [ -e "$a" ] || continue
  cmp -s "$a" "$PD/${a##*/}" || { patch -d "$SRC" -p1 -R -s < "$a"; rm "$a"; }
done
for p in "$PD"/*.patch; do
  [ -e "$p" ] && [ ! -e "$A/${p##*/}" ] || continue
  if patch -d "$SRC" -p1 -R -s -f --dry-run < "$p" >/dev/null 2>&1; then
    echo "   ${p##*/}: already in the kernel source, skipped"; continue; fi
  patch -d "$SRC" -p1 -s -N < "$p"; cp "$p" "$A/"
done
# KBUILD_GENDWARFKSYMS_STABLE: GKI computes symbol CRCs in "--stable" (kABI-aware) mode; without
# it every CRC touching a struct differs and vendor modules fail with "disagrees about version".
MK=(make -C "$SRC" -j"$(nproc)" LLVM=1 LLVM_IAS=1 ARCH=x86_64 O="$O" KBUILD_GENDWARFKSYMS_STABLE=1)
cp "$CFG" "$O/.config"; cp "$O/.config" "$O/.config.orig"
SC() { "$SRC/scripts/config" --file "$O/.config" "$@"; }
# same release string as the GKI build so vermagic matches the image's prebuilt modules
# (keep LOCALVERSION_AUTO: MODULE_SCMVERSION depends on it and changes struct module, i.e. the
#  module_layout CRC every vendor module checks; a source tarball has no SCM info to append anyway)
SC --set-str LOCALVERSION "-${REL#*-}"
# keep every export (no KMI trimming); unsigned (vendor) modules allowed
SC -d TRIM_UNUSED_KSYMS -d MODULE_SIG_FORCE
# Trust Google's GKI module signing key (from the image's vmlinux, tools/extract-certs.sh): GKI
# modules carry "protected" export flags baked in by Google's modpost, and a module whose
# signature we can't verify may not use them (system_dlkm zram -> zsmalloc refused otherwise).
[ -n "${CHURRO_GKI_CERTS:-}" ] && SC --set-str SYSTEM_TRUSTED_KEYS "$(realpath "$CHURRO_GKI_CERTS")"
for c in $Y; do SC -e "$c"; done; for c in $M; do SC -m "$c"; done; for c in $N; do SC -d "$c"; done
"${MK[@]}" olddefconfig >/dev/null
# distro module set (profile DISTRO_*): options the distro builds as modules that we don't have
# yet, limited to driver directories (Kconfig file that defines the symbol)
if [ -n "${DISTRO_CONFIG:-}" ]; then
  # cached per URL: a new ARCH_LINUX_CONFIG_TAG downloads its config again
  [ -s "$O/distro.config" ] && [ "$(cat "$O/distro.url" 2>/dev/null)" = "$DISTRO_CONFIG" ] ||
    { curl -fsSL --retry 3 -o "$O/distro.config" "$DISTRO_CONFIG"; echo "$DISTRO_CONFIG" > "$O/distro.url"; }
  (cd "$SRC" && grep -rH -E '^(menu)?config [A-Za-z0-9_]+' --include='Kconfig*' . ) |
    sed -E 's#^\./([^:]+):(menu)?config ([A-Za-z0-9_]+).*#\3 \1#' | sort -u -k1,1 > "$O/sym2file"
  # tristate options: the distro's built-in ones (=y: battery, thermal, USB 1.1, ...) come as modules
  (cd "$SRC" && find . -name 'Kconfig*' -not -path './out*' | xargs awk '/^(menu)?config /{c=$2; next}
    c && /^[ \t]+(def_)?tristate/{print c; c=""} c && /^[ \t]+(def_bool|bool|int|hex|string)/{c=""}') | sort -u > "$O/tristates"
  # what each option needs positively: its "depends on" lines + the "if" blocks around it in its
  # Kconfig file (negations and "= n" dropped), for the dependency closure below
  (cd "$SRC" && find . -name 'Kconfig*' -not -path './out*' | xargs awk 'FNR==1{n=0; c=""}
    /^if[ \t]/{s=$0; sub(/^if[ \t]+/,"",s); st[++n]=s; next} /^endif/{if(n) n--; next}
    /^(menu)?config[ \t]/{c=$2; for(i=1;i<=n;i++) print c, st[i]; next} /^[^ \t#]/{c=""}
    c && /^[ \t]+depends on[ \t]/{s=$0; sub(/^[ \t]+depends on[ \t]+/,"",s); print c, s}') |
    sed -E 's/![ \t]*\(?[A-Za-z0-9_]+//g; s/[A-Za-z0-9_]+[ \t]*!?=[ \t]*[nmy]([^A-Za-z0-9_]|$)/\1/g' |
    awk '{for(i=2;i<=NF;i++){t=$i; gsub(/[^A-Za-z0-9_]/,"",t); if(t ~ /^[A-Z][A-Z0-9_]+$/) print $1, t}}' | sort -u > "$O/deps"
  on() { grep -oE '^CONFIG_[A-Za-z0-9_]+=[ym]$' "$1" | sed 's/^CONFIG_//; s/=.$//' | sort -u; }
  # A dependency that is a bool may only be one that adds no code of its own to the kernel image:
  # in Makefiles it only opens directories (obj-$(CONFIG_X) += dir/) or adds files to a module
  # that is =m. Real built-in drivers (PWM core, PINCTRL_AMD, ...) are the profile's Y list.
  # What the dependencies switch on in turn may not have code of its own either, nor be tested in
  # a core header (struct layouts -> GKI export CRCs): checked below, culprits left out.
  (cd "$SRC" && cat include/linux/*.h include/linux/sched/*.h include/net/*.h include/net/netns/*.h arch/x86/include/asm/*.h) |
    grep -oE 'CONFIG_[A-Za-z0-9_]+' | sed 's/^CONFIG_//' | sort -u > "$O/corehdr"
  (cd "$SRC" && find drivers sound \( -name Makefile -o -name Kbuild \) -print0 | xargs -0 awk 'FNR==1{b=""}
    /\\$/{l=$0; sub(/\\$/,"",l); b=b l " "; next} {l=b $0; b=""; if (l !~ /^[ \t]*(#|$)/) print FILENAME "\t" l}') > "$O/mklines"
  # where C code tests the distro's bools: "symbol<TAB>file"
  grep -oE '^CONFIG_[A-Za-z0-9_]+=y$' "$O/distro.config" | sed 's/^CONFIG_//; s/=y$//' | sort -u | comm -23 - "$O/tristates" > "$O/dbools"
  (cd "$SRC" && grep -rIoE --include='*.[ch]' --exclude-dir='out*' --exclude-dir=tools --exclude-dir=scripts --exclude-dir=samples --exclude-dir=Documentation 'CONFIG_[A-Za-z0-9_]+' .) |
    sed -E 's#^\./##; s#:CONFIG_#\t#; s#_MODULE$##' | awk -F'\t' 'NR==FNR{b[$1]=1; next} ($2 in b){print $2 "\t" $1}' "$O/dbools" - | sort -u > "$O/crefs"
  impure() {   # options whose Makefile or C use isn't "free" with the current .config (see above)
    {
    awk -F'\t' '
      function cfgs(t,   r) { r=""; while (match(t,/CONFIG_[A-Za-z0-9_]+/)) { r=r " " substr(t,RSTART+7,RLENGTH-7); t=substr(t,RSTART+RLENGTH) } return r }
      function free(f,l,   h,lhs,it,n,i,q) {   # does this line add only directories or module parts?
        if (!match(l,/^[ \t]*[A-Za-z0-9_.-]+-(\$\(CONFIG_[A-Za-z0-9_]+\)|y|m|objs)[ \t]*[:+]?=/)) return 0
        h=substr(l,RSTART,RLENGTH); lhs=h; sub(/^[ \t]+/,"",lhs); sub(/-(\$\(CONFIG_.*|y|m|objs)[ \t]*[:+]?=$/,"",lhs)
        if (lhs == "obj") { if (h ~ /obj-m/) return 1; n=split(substr(l,RLENGTH+1),it,/[ \t]+/)
          for (i=1;i<=n;i++) if (it[i] != "" && it[i] !~ /\/$/) return 0; return 1 }
        if (lhs ~ /flags|^lib$|^always|^targets|^subdir/) return 0
        q=par[f SUBSEP lhs]; return (q == "m" || (q != "" && v[q] == "m")) }
      NR==FNR{if (match($0,/^CONFIG_[A-Za-z0-9_]+=/)) v[substr($0,8,RLENGTH-8)]=substr($0,RLENGTH+1); next}
      { f=$1; l=substr($0,length($1)+2)
        if (f != pf) { d=0; pf=f }
        if (l ~ /^[ \t]*(ifeq|ifneq|ifdef|ifndef)[ \t(]/) { cs[++d]=cfgs(l); next }
        if (l ~ /^[ \t]*else/) next
        if (l ~ /^[ \t]*endif/) { if (d) d--; next }
        if (match(l,/^[ \t]*obj-(\$\(CONFIG_[A-Za-z0-9_]+\)|[my])[ \t]*[:+]?=/)) {
          p=substr(l,RSTART,RLENGTH); gsub(/^[ \t]*obj-|\$\(CONFIG_|\)|[ \t]*[:+]?=$/,"",p)
          n=split(substr(l,RLENGTH+1),it,/[ \t]+/)
          for (i=1;i<=n;i++) if (it[i] ~ /\.o$/) { o=it[i]; sub(/\.o$/,"",o); par[f SUBSEP o]=p } }
        c=""; for (i=1;i<=d;i++) c=c cs[i]; L[NR]=l; F[NR]=f; C[NR]=c }
      END { for (k in L) { l=L[k]; f=F[k]; ok=free(f,l)
          # the line s own option (lhs-$(CONFIG_X)), any other option it names, enclosing ifeq/ifdef
          x=""; if (match(l,/^[ \t]*[A-Za-z0-9_.-]+-\$\(CONFIG_[A-Za-z0-9_]+\)/)) { x=substr(l,RSTART,RLENGTH); sub(/^.*\$\(CONFIG_/,"",x); sub(/\)$/,"",x) }
          if (x != "" && !ok) bad[x]=1
          n=split(cfgs(substr(l,RLENGTH > 0 && x != "" ? RSTART+RLENGTH : 1)),zz," "); for (i=1;i<=n;i++) bad[zz[i]]=1
          if (!ok) { n=split(C[k],zz," "); for (i=1;i<=n;i++) bad[zz[i]]=1 } }
        for (b in bad) print b }' "$O/.config" "$O/mklines" | sort -u
    # C code testing a bool (#ifdef, IS_ENABLED): free only in files of modules that are =m, or in
    # driver-local headers of directories that build nothing into the kernel
    awk -F'\t' 'NR==FNR{if (match($0,/^CONFIG_[A-Za-z0-9_]+=/)) v[substr($0,8,RLENGTH-8)]=substr($0,RLENGTH+1); next}
      FILENAME ~ /mklines$/ { f=$1; l=substr($0,length($1)+2); D=f; sub(/\/[^\/]*$/,"",D)
        if (!match(l,/^[ \t]*[A-Za-z0-9_.-]+-(\$\(CONFIG_[A-Za-z0-9_]+\)|y|m|objs)[ \t]*[:+]?=/)) next
        h=substr(l,RSTART,RLENGTH); lhs=h; sub(/^[ \t]+/,"",lhs); sub(/-(\$\(CONFIG_.*|y|m|objs)[ \t]*[:+]?=$/,"",lhs)
        p=h; gsub(/^[ \t]*[A-Za-z0-9_.-]+-|\$\(CONFIG_|\)|[ \t]*[:+]?=$/,"",p)
        n=split(substr(l,RLENGTH+1),it,/[ \t]+/)
        for (i=1;i<=n;i++) if (it[i] ~ /\.o$/) { o=it[i]; sub(/\.o$/,"",o)
          if (lhs == "obj") { par[D "/" o]=p; if (p == "y" || v[p] == "y") bi[D]=1 } else comp[D "/" o]=D "/" lhs }
        next }
      { s=$1; f=$2; D=f; sub(/\/[^\/]*$/,"",D)
        if (f !~ /^(drivers|sound)\//) { bad[s]=1; next }
        if (f ~ /\.h$/) { if (bi[D]) bad[s]=1; next }
        rel=f; sub(/\.c$/,"",rel); q=""
        for (A=D; A ~ /\//; sub(/\/[^\/]*$/,"",A)) { k=A "/" substr(rel,length(A)+2)
          if (k in par) { q=par[k]; break }; if (k in comp) { q=par[comp[k]]; break } }
        if (!(q == "m" || v[q] == "m")) bad[s]=1 }
      END { for (b in bad) print b }' "$O/.config" "$O/mklines" "$O/crefs" | sort -u; } | sort -u; }
  { grep -oE '^CONFIG_[A-Za-z0-9_]+=m$' "$O/distro.config" | sed 's/^CONFIG_//; s/=m$//'
    grep -oE '^CONFIG_[A-Za-z0-9_]+=y$' "$O/distro.config" | sed 's/^CONFIG_//; s/=y$//' | sort -u | comm -12 - "$O/tristates"; } | sort -u |
    join - "$O/sym2file" | awk -v dirs="$DISTRO_DIRS" -v deny="$DISTRO_DENY" '$2 ~ dirs && $1 !~ deny {print $1}' |
    while read -r c; do grep -qE "^CONFIG_$c=[ym]$" "$O/.config" || echo "$c"; done > "$O/distro.add"
  # the distro's own bool options in driver directories (module sub-options, vendor menus,
  # protocol extensions like MOUSE_PS2_ELANTECH): candidates for the closure too, same rules
  grep -oE '^CONFIG_[A-Za-z0-9_]+=y$' "$O/distro.config" | sed 's/^CONFIG_//; s/=y$//' | sort -u | comm -23 - "$O/tristates" |
    join - "$O/sym2file" | awk -v dirs="$DISTRO_DIRS" -v deny="$DISTRO_DENY" '$2 ~ dirs && $1 !~ deny {print $1}' > "$O/distrobools"
  cp "$O/.config" "$O/.config.predistro"
  # A module can switch on (select) built-in options. Those that change core structs (fields
  # under #ifdef in netdevice.h, i2c.h, ...) change the CRC of hundreds of GKI exports, so
  # Google's prebuilt modules would stop loading: leave out whatever pulls them in, following
  # select chains, until no such option is left.
  (cd "$SRC" && find . -name 'Kconfig*' -not -path './out*' | xargs awk '/^(menu)?config /{c=$2}
    /^[ \t]+(select|imply)[ \t]+[A-Za-z0-9_]+/{print $2, c}') | sort -u > "$O/selects"   # "selected selector"
  # options core headers test (struct fields, mostly)
  (cd "$SRC" && cat include/linux/{netdevice,skbuff,sched,fs,mm_types,device,i2c,pci,usb,cgroup-defs,blkdev,blk_types,bio,interrupt,irq,workqueue,timer,module}.h \
     include/linux/sched/*.h include/net/{sock,net_namespace,dst}.h include/net/netns/*.h) |
    grep -oE 'CONFIG_[A-Za-z0-9_]+' | sed 's/^CONFIG_//' | sort -u > "$O/coresyms"
  : > "$O/distro.dep"; : > "$O/depdeny"
  for i in $(seq 1 40); do
    # WLAN vendor menu bools =y: Google's GKI config enables only a few (ath, microchip, ...),
    # and olddefconfig silently drops every symbol inside a closed vendor menu - all of
    # Realtek/MediaTek/Broadcom's drivers vanished that way (G20AJ's RTL8821AE: no module).
    # The bools come from the tree (each vendor's own Kconfig), so any new vendor is covered;
    # =y costs nothing on its own.
    cp "$O/.config.predistro" "$O/.config"
    SC $(sed 's/^/-m /' "$O/distro.add") $(awk 'NR==FNR{t[$1]=1; next} {print (t[$1] ? "-m " : "-e ") $1}' "$O/tristates" "$O/distro.dep") $(sed -n 's/^config \(WLAN_VENDOR_[A-Z0-9_]*\)$/-e \1/p' "$SRC"/drivers/net/wireless/*/Kconfig)
    "${MK[@]}" olddefconfig >/dev/null
    grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$O/.config" | grep -vxFf "$O/.config.predistro" | sed 's/^CONFIG_//; s/=y$//' | sort > "$O/newy"
    comm -12 "$O/newy" "$O/coresyms" | grep -vxF -f <(printf '%s\n' ${DISTRO_BUILTIN_OK:-} x) > "$O/forbid" || true
    if [ ! -s "$O/forbid" ]; then
      impure > "$O/impure"
      [ -s "$O/distro.dep" ] || cp "$O/newy" "$O/newy0"   # what the module list alone switches on
      comm -23 "$O/newy" "$O/newy0" | comm -23 - <(sort -u "$O/distro.dep") | comm -12 - <(sort -u "$O/corehdr" "$O/impure") > "$O/risky"
      if [ -s "$O/risky" ]; then
        # walk up the select / depends-on graph through newly enabled options to our dependencies
        on "$O/.config" | comm -23 - <(on "$O/.config.predistro") > "$O/newon"
        # selects first; "depends on" edges (defaults switching on with their menu) only if those find none
        : > "$O/culp"
        for edges in "$O/selects" "$O/selects $O/deps"; do
          cp "$O/risky" "$O/w"; : > "$O/seen"
          while [ -s "$O/w" ]; do
            sort -u "$O/seen" "$O/w" -o "$O/seen"
            for e in $edges; do join "$O/w" "$e"; done 2>/dev/null | awk '{print $2}' | sort -u > "$O/par"
            comm -12 "$O/par" <(sort -u "$O/distro.dep") >> "$O/culp"
            comm -12 "$O/par" "$O/newon" | comm -23 - "$O/seen" | comm -23 - <(sort -u "$O/distro.dep") > "$O/w"
          done
          [ -s "$O/culp" ] && break
        done
        sort -u "$O/culp" -o "$O/culp"
        [ -s "$O/culp" ] || { echo "   distro modules: can't tell which dependency switches on $(tr '\n' ' ' < "$O/risky")- dependency closure off"; cp "$O/distro.dep" "$O/culp"; }
        echo "   distro modules: built-in side effects $(tr '\n' ' ' < "$O/risky")-> leaving out dependencies $(tr '\n' ' ' < "$O/culp")"
        cat "$O/culp" >> "$O/depdeny"; sort -u "$O/distro.dep" | comm -23 - "$O/culp" > "$O/d"; mv "$O/d" "$O/distro.dep"; continue
      fi
      # dependency closure: list modules (and dependencies) olddefconfig dropped miss an option;
      # switch on the ones the distro has on (tristate -> m, bool -> y), in driver directories,
      # not denied, not already left out; the forbid walk above then judges them like the rest
      { sort -u "$O/distro.add" "$O/distro.dep" | comm -23 - <(on "$O/.config") | join - "$O/deps" | awk '{print $2}'
        cat "$O/distrobools"; } | sort -u | join - "$O/sym2file" | awk -v deny="$DISTRO_DENY" '$2 ~ /^(drivers|sound)\// && $1 !~ deny {print $1}' |
        comm -12 - <(on "$O/distro.config") | comm -23 - <(on "$O/.config") | comm -23 - "$O/distro.dep" |
        comm -23 - <(sort -u "$O/depdeny") > "$O/depcand" || true
      # bools: only those that add no code of their own (above)
      { comm -12 "$O/depcand" "$O/tristates"; comm -23 "$O/depcand" "$O/tristates" | comm -23 - "$O/impure"; } | sort -u > "$O/depnew"
      [ -s "$O/depnew" ] || break
      echo "   distro modules: + dependencies $(tr '\n' ' ' < "$O/depnew")"
      sort -u "$O/distro.dep" "$O/depnew" -o "$O/distro.dep"; continue
    fi
    echo "   distro modules: core built-in side effects: $(tr '\n' ' ' < "$O/forbid")"
    # walk the select graph back to modules in distro.add; intermediate selectors (enabled by us,
    # not in the list) are forbidden too
    sort -u "$O/forbid" > "$O/walk"; before=$(cat "$O/distro.add" "$O/distro.dep" | wc -l)
    # a dependency we switched on is forbidden itself: leave it out (its modules stay out)
    while read -r t; do grep -qx "$t" "$O/distro.dep" && { sed -i "/^$t\$/d" "$O/distro.dep"; echo "$t" >> "$O/depdeny"; echo "     leaving out dependency $t"; }; done < "$O/walk"
    while [ -s "$O/walk" ]; do
      join "$O/walk" "$O/selects" 2>/dev/null | awk '{print $2}' | sort -u > "$O/sel"; : > "$O/walk"
      while read -r t; do
        if grep -qx "$t" "$O/distro.add"; then sed -i "/^$t\$/d" "$O/distro.add"; echo "     leaving out $t"
        elif grep -qx "$t" "$O/distro.dep"; then sed -i "/^$t\$/d" "$O/distro.dep"; echo "$t" >> "$O/depdeny"; echo "     leaving out dependency $t"
        elif grep -qE "^CONFIG_$t=[ym]$" "$O/.config" && ! grep -qE "^CONFIG_$t=[ym]$" "$O/.config.predistro" && ! grep -qx "$t" "$O/forbid"; then
          echo "$t" >> "$O/forbid"; echo "$t" >> "$O/walk"; fi
      done < "$O/sel"
      sort -u "$O/walk" -o "$O/walk"
    done
    [ "$(cat "$O/distro.add" "$O/distro.dep" | wc -l)" -lt "$before" ] || { echo "distro modules: can't tell which module enables $(tr '\n' ' ' < "$O/forbid")- add it to DISTRO_DENY" >&2; exit 1; }
  done
  # never weaken a built-in option (a module dependency can downgrade y to m)
  down=$(grep -E '=y$' "$O/.config.predistro" | grep -vxFf "$O/.config" || true)
  [ -z "$down" ] || { echo "distro modules would weaken built-in options:" >&2; echo "$down" >&2; exit 1; }
  echo "== distro modules: $(wc -l < "$O/distro.add") options added, + $(wc -l < "$O/distro.dep") they depend on; still unbuildable: $(sort -u "$O/distro.add" | comm -23 - <(on "$O/.config") | wc -l)"
fi
for f in $(grep -oE '_LIST="[^"]+"' "$O/.config" | cut -d'"' -f2); do [ -e "$SRC/$f" ] || : > "$SRC/$f"; done
echo "== config delta vs shipped kernel (built-in options; $(grep -c '=m$' "$O/.config") modules):"
diff <(grep -E '^CONFIG_' "$O/.config.orig" | grep -v '=m$' | sort) <(grep -E '^CONFIG_' "$O/.config" | grep -v '=m$' | sort) | grep -E '^[<>]' || true
echo "$(cat "$O/include/config/kernel.release" 2>/dev/null)"
"${MK[@]}" bzImage modules 2>&1 | grep -E 'error|Error|WARNING: modpost' | head -40 || true
mkdir -p "$OUT/modules"
cp "$O/arch/x86/boot/bzImage" "$OUT/kernel"
cat "$O/include/config/kernel.release" > "$OUT/kernel.release"
"${MK[@]}" INSTALL_MOD_PATH="$OUT/modroot" INSTALL_MOD_STRIP=1 modules_install >/dev/null
echo "built $(cat "$OUT/kernel.release") -> $OUT"
