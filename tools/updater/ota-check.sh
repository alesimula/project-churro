#!/usr/bin/env bash
# Ask Google's checkin server which OTA it offers a build, like GMS SystemUpdate does.
# Usage: tools/updater/ota-check.sh <fingerprint | recovery.bin> [--chain] [--html]
#          stdout: KEY=value lines, safe to eval (like buildinfo.sh); a human summary goes to stderr:
#            FROM                    fingerprint that was checked
#            DELTA_PKG               delta package URL (empty if the server offered none)
#            DELTA_NFO               target build fingerprint
#            DELTA_PATCH, DELTA_SIZE security patch level, size in bytes
#          Only deltas are reported (apply one with tools/updater/ota-update.sh).
#          --chain  keep asking with each target build; stdout is then the URLs, one per line
#          --html   print an HTML table instead
#        tools/updater/ota-check.sh --serve [port]   browser UI on http://127.0.0.1:8080/ (busybox httpd)
# Anonymous checkin (random serial/IMEI/MAC, android id 0); field set from
# github.com/tangalbert919/google-ota-prober. fetchSystemUpdates (field 29) is what makes the
# server add update_* settings. Each package's target build comes from its zip's
# META-INF/com/android/metadata (stored uncompressed near the start: first 16 KiB are enough).
# The build timestamp (ro.build.date.utc, known for a recovery.bin) is sent like the device does;
# without it the server may offer an older build, so offers not newer than the source are dropped.
# Seen Oct 2026 (ruby): 271.R1 gets the 271.R1 -> 276.R4 delta.
# OTA_TS=<ro.build.date.utc> sets the build timestamp when checking a bare fingerprint.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FP_RE='^[^/]+/[^/]+/[^/:]+:[^/]+/[^/]+/[^/:]+:[^/]+/[^/]+$'   # brand/product/device:release/id/incremental:type/tags

# --- minimal protobuf writer: everything is built as \xHH escapes, written with printf %b ---
hex()  { printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n' | sed 's/../\\x&/g'; }
vint() { local n=$1 o=""; while [ "$n" -ge 128 ]; do o+=$(printf '\\x%02x' $(( (n & 127) | 128 ))); n=$((n >> 7)); done
         printf '%s\\x%02x' "$o" "$n"; }
fi_()  { vint $(($1 << 3)); vint "$2"; }                          # varint field
fm()   { vint $(($1 << 3 | 2)); vint $((${#2} / 4)); printf '%s' "$2"; }   # bytes field (escaped payload)
fs()   { fm "$1" "$(hex "$2")"; }                                 # string field
rnd()  { tr -dc "$1" </dev/urandom | head -c "$2"; }

# checkin <fingerprint> <build timestamp or 0> <response file>
checkin() {
  local fp=$1 dev rel bid build ck req
  dev=$(cut -d/ -f3 <<<"$fp" | cut -d: -f1); rel=$(cut -d: -f2 <<<"$fp" | cut -d/ -f1); bid=$(cut -d/ -f4 <<<"$fp")
  build=$(fs 1 "$fp"; fi_ 7 "$2"; fs 9 "$dev")
  ck=$(fm 1 "$build"; fi_ 2 0; fs 8 "WIFI::"; fi_ 9 0; fi_ 14 2; fi_ 18 0; fs 19 WIFI)   # deviceType, voiceCapable
  req=$(fs 1 "$(rnd 0-9 15)"; fi_ 2 0; fs 3 "1-$(rnd 0-9a-f 40)"; fm 4 "$ck"; fs 6 en-US
        fs 9 "$(rnd 0-9a-f 12)"; fs 12 America/New_York; fi_ 14 3; fs 16 "$(rnd 0-9a-f 8)"; fs 19 wifi
        fi_ 20 0; fi_ 22 0; fi_ 29 1; fi_ 30 0)
  printf '%b' "$req" | gzip | curl -fsS --compressed --max-time 30 --data-binary @- -o "$3" \
    -H 'Content-Type: application/x-protobuffer' -H 'Content-Encoding: gzip' \
    -H "User-Agent: Dalvik/2.1.0 (Linux; U; Android $rel; $dev Build/$bid)" https://android.googleapis.com/checkin
  if [ "$(head -c2 "$3" | od -An -tx1 | tr -d ' ')" = 1f8b ]; then gunzip -c "$3" >"$3.raw" && mv "$3.raw" "$3"; fi
}

# setting <response file> <name>: value of GservicesSetting {1: name, 2: value} (empty if absent).
# grep is line-based and the field tag is \x0a, so match "<name>\x12" and check the length byte before it.
setting() {
  local f=$1 n=$2 off p b len=0 s=0
  for off in $(LC_ALL=C grep -obUaP "$n\\x12" "$f" | cut -d: -f1); do
    [ "$(od -An -tu1 -j $((off - 1)) -N1 "$f" | tr -d ' ')" = ${#n} ] || continue
    p=$((off + ${#n} + 1))
    while :; do b=$(od -An -tu1 -j $p -N1 "$f" | tr -d ' '); p=$((p + 1))
      len=$((len | (b & 127) << s)); s=$((s + 7)); [ "$b" -lt 128 ] && break; done
    dd if="$f" bs=1 skip=$p count=$len status=none; return 0
  done
}

# offers <fingerprint> <follow 0|1> [build timestamp]: one line per offered package
# ("|"-separated: tab would merge empty fields in read):   type|target-build|security-patch|size-bytes|url
offers() {
  local fp=$1 follow=$2 src=${3:-0} url md to pre spl ts size
  while :; do
    checkin "$fp" "$src" "$T/resp"
    url=$(setting "$T/resp" update_url); [ -n "$url" ] || break
    size=$(setting "$T/resp" update_size_value)
    md=$(curl -fsSL -r 0-16383 "$url" | tr -c '[:print:]\n' '\n')
    to=$(sed -n 's/^post-build=//p' <<<"$md"); pre=$(sed -n 's/^pre-build=//p' <<<"$md")
    spl=$(sed -n 's/^post-security-patch-level=//p' <<<"$md"); ts=$(sed -n 's/^post-timestamp=//p' <<<"$md")
    newer "$to" "$fp" || break
    [ -n "$pre" ] || break                                    # only deltas
    printf 'delta|%s|%s|%s|%s\n' "$to" "$spl" "${size:-0}" "$url"
    [ "$follow" = 1 ] || break
    fp=$to; src=${ts:-0}
  done
}

# newer <target fingerprint> <source fingerprint>: target's incremental build number is higher
newer() {
  local a b; a=$(cut -d/ -f5 <<<"$1" | cut -d: -f1); b=$(cut -d/ -f5 <<<"$2" | cut -d: -f1)
  [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || return 0        # non-numeric: can't tell, keep it
  [ "$a" -gt "$b" ]
}

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
html_page() {   # html_page <fingerprint> <chain 0|1> <offers lines>
  cat <<HTML
<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width"><title>Churro OTA check</title>
<style>body{font:15px system-ui;margin:2em auto;max-width:72em;padding:0 1em}input[type=text]{width:min(46em,100%)}
table{border-collapse:collapse;margin-top:1em}td,th{border:1px solid #8886;padding:.3em .6em;text-align:left}</style>
<h1>OTA check</h1><form><input type=text name=fp value="$(esc <<<"$1")" placeholder="Brand/product/device:release/id/incremental:user/release-keys">
<label><input type=checkbox name=chain value=1 $([ "$2" = 1 ] && echo checked)> follow chain</label> <button>Check</button></form>
HTML
  [ -n "$1" ] || return 0
  [[ $1 =~ $FP_RE ]] || { echo "<p>Not a build fingerprint.</p>"; return 0; }
  [ "$3" != ERR ] || { echo "<p>Checkin failed (network or server error).</p>"; return 0; }
  [ -n "$3" ] || { echo "<p>No update offered for this fingerprint.</p>"; return 0; }
  echo "<table><tr><th>#</th><th>Type</th><th>Target build</th><th>Patch</th><th>Size</th><th>Package</th></tr>"
  local i=0 type to spl size url
  while IFS='|' read -r type to spl size url; do i=$((i + 1))
    printf '<tr><td>%s</td><td>%s</td><td><code>%s</code></td><td>%s</td><td>%s MB</td><td><a href="%s">%s</a></td></tr>\n' \
      $i "$type" "$(esc <<<"$to")" "$spl" $((size / 1000000)) \
      "$(esc <<<"$url")" "$(esc <<<"${url##*/}")"
  done <<<"$3"
  echo "</table>"
}

# --- CGI (run by busybox httpd from --serve, or any CGI server) ---
if [ -n "${GATEWAY_INTERFACE:-}" ]; then
  fp="" chain=0
  for kv in ${QUERY_STRING//&/ }; do v=${kv#*=}; v=${v//+/ }; v=$(printf '%b' "${v//%/\\x}")
    case $kv in fp=*) fp=$(sed 's/^ *//; s/ *$//' <<<"$v") ;; chain=1) chain=1 ;; esac; done
  printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'
  res=""; [[ $fp =~ $FP_RE ]] && { res=$(offers "$fp" "$chain" 2>/dev/null) || res=ERR; }
  html_page "$fp" "$chain" "$res"
  exit 0
fi

case ${1:-} in
  ""|-h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  --serve)
    command -v busybox >/dev/null || { echo "--serve needs busybox (apt install busybox)" >&2; exit 1; }
    mkdir -p "$T/www/cgi-bin"; ln -s "$HERE/ota-check.sh" "$T/www/cgi-bin/ota"
    printf '<meta http-equiv=refresh content="0;url=/cgi-bin/ota">' >"$T/www/index.html"
    echo "http://127.0.0.1:${2:-8080}/   (Ctrl+C to stop)" >&2
    busybox httpd -f -p "127.0.0.1:${2:-8080}" -h "$T/www"; exit ;;   # ponytail: localhost only, no auth
esac

# ---- args: first positional = fingerprint|recovery.bin; flags may appear anywhere ----
src=${OTA_TS:-0} fp="" follow=0 html=0
while [ $# -gt 0 ]; do
  case $1 in
    --chain) follow=1 ;; --html) html=1 ;;
    -*) ;; *) [ -n "$fp" ] || fp=$1 ;;
  esac; shift
done

if [ -n "$fp" ] && [ -f "$fp" ]; then
  if bo=$("$HERE/buildinfo.sh" "$fp" 2>/dev/null); then eval "$bo"; fp=${FINGERPRINT:-}; src=${DATE_UTC:-0}
  else echo "buildinfo.sh failed on $fp" >&2; exit 1; fi
fi

[[ $fp =~ $FP_RE ]] || { echo "not a build fingerprint: $fp" >&2; exit 1; }
echo "from: $fp" >&2
res=$(offers "$fp" "$follow" "$src")
[ "$html" = 1 ] && { html_page "$fp" "$follow" "$res"; exit 0; }
[ -n "$res" ] || { echo "no delta offered" >&2; exit 1; }
declare -A out=()
while IFS='|' read -r type to spl size url; do
  printf '%-5s -> %s  patch %s  %s MB\n' "$type" "$to" "$spl" $((size / 1000000)) >&2
  if [ "$follow" = 1 ]; then echo "$url"; continue; fi
  [ -z "${out[PKG]:-}" ] || continue                         # first delta only
  out[PKG]=$url out[NFO]=$to out[PATCH]=$spl out[SIZE]=$size
done <<<"$res"
[ "$follow" = 1 ] && exit 0
printf 'FROM=%q\n' "$fp"
for f in PKG NFO PATCH SIZE; do printf 'DELTA_%s=%q\n' $f "${out[$f]:-}"; done
