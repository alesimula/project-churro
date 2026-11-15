#!/usr/bin/env bash
# Built-in audio on PCs. Googlebook's audio HAL (dras, APEX com.android.hardware.audio.desktop)
# takes its card name and config dir from Google's hardware mapping table, whose default is
# Lenovo's board: dir /vendor/etc/audio/sof-rt5682_alc5682ivs_tas2563, card hw:sofrt5682. No PC
# has that card: after 10 s "Primary module audio will not work" - only USB/Bluetooth audio.
# We add generic configs, one per ALSA card ID, in etc/audio/<id>. At boot get_variant_audio
# finds the PC's card and sets vendor.audio.soundcard.name (the HAL's card-name override) and
# vendor.audio.churro.card; init then bind-mounts etc/audio/<id> over the board dir(s), so the
# HAL reads our config whichever dir it resolves, and restarts the HAL (churro-audio.rc).
# Covered: HD-audio codecs on the legacy driver (snd_hda_intel: "PCH" Intel, "Generic*" AMD,
# "Intel" older Intel/QEMU) and on SOF's generic HDA machine ("sofhdadsp", laptops with DMICs).
# Speaker and headphones share PCM 0 (the kernel's HDA auto-mute switches between them);
# outputs come up unmuted at 0 dB (HDA generic parser), the HAL applies volume in software.
set -euo pipefail
T=$1; A=$T/etc/audio; F=$(dirname "$0"); S=$T/etc/selinux
CFG=u:object_r:vendor_configs_file:s0
boards=(); for d in "$A"/*/; do d=${d%/}; [ -f "$d/audio_config.xml" ] && boards+=("${d##*/}"); done
[ ${#boards[@]} -gt 0 ] || { echo "audio-generic: no board audio config in $A" >&2; exit 1; }

# The card ID the HAL waits for comes from Google's mapping table (not from the config dir), so
# init renames the PC's card to it (ALSA allows that via /sys/class/sound/cardN/id); our configs
# address the card by that name.
W=$(sed -n 's|.*<SoundCardName>hw:\([^<]*\)</SoundCardName>.*|\1|p' "$A/${boards[0]}/audio_config.xml")
[ -n "$W" ] || { echo "audio-generic: no SoundCardName in ${boards[0]}" >&2; exit 1; }
ids=()
# cfg <dir name> <card id> <jack device prefix> <internal mic PCM> [<HDMI PCM>...]
cfg() {
  local name=$1 id=$2 jp=$3 mic=$4 d=$A/$1 n=0 h; shift 4
  mkdir -p "$d"; ids+=("$name")
  { printf '<?xml version="1.0" encoding="utf-8"?>\n<!-- Project Churro audio-generic: ALSA card %s, renamed %s at boot -->\n<audio_config>\n' "$id" "$W"
    printf '\t<SoundCardName>hw:%s</SoundCardName>\n\t<HiFi>\n' "$W"
    # same fields as Google's board config (DSPLatency on every non-HDMI node, mic channel map).
    # Volume: in software (no PlaybackMixerElem); churro-mixer puts the hardware at 0 dB first.
    # JackDev = the jack's input device ("<card name> Headphone"/"Mic" on HD-audio codecs).
    printf '\t\t<Headphone>\n\t\t\t<PlaybackPCM>hw:%s,0</PlaybackPCM>\n' "$W"
    printf '\t\t\t<JackDev>%s Headphone</JackDev>\n\t\t\t<JackSwitch>2</JackSwitch>\n\t\t\t<DSPLatency>0</DSPLatency>\n\t\t</Headphone>\n' "$jp"
    printf '\t\t<InternalMic>\n\t\t\t<CapturePCM>hw:%s,%s</CapturePCM>\n' "$W" "$mic"
    printf '\t\t\t<CaptureChannelMap>\n\t\t\t\t<FL>0</FL>\n\t\t\t\t<FR>1</FR>\n\t\t\t</CaptureChannelMap>\n'
    printf '\t\t\t<IntrinsicSensitivity>-2600</IntrinsicSensitivity>\n\t\t\t<DSPLatency>0</DSPLatency>\n\t\t</InternalMic>\n'
    printf '\t\t<Mic>\n\t\t\t<CapturePCM>hw:%s,0</CapturePCM>\n\t\t\t<JackDev>%s Mic</JackDev>\n\t\t\t<DSPLatency>0</DSPLatency>\n\t\t</Mic>\n' "$W" "$jp"
    printf '\t\t<Speaker>\n\t\t\t<PlaybackPCM>hw:%s,0</PlaybackPCM>\n\t\t\t<DSPLatency>0</DSPLatency>\n\t\t</Speaker>\n' "$W"
    for h; do n=$((n+1))
      printf '\t\t<HDMI%d>\n\t\t\t<PlaybackPCM>hw:%s,%s</PlaybackPCM>\n' $n "$W" "$h"
      printf '\t\t\t<JackDev>%s HDMI/DP,pcm=%s</JackDev>\n\t\t\t<PlaybackChannels>2</PlaybackChannels>\n\t\t</HDMI%d>\n' "$jp" "$h" $n
    done
    printf '\t</HiFi>\n</audio_config>\n'; } > "$d/audio_config.xml"
  # No control values here: libaudioroute needs one value per channel, and channel counts and
  # ranges differ per codec (QEMU's "Master" is a stereo DAC volume, Realtek's a mono virtual
  # master) - churro-mixer reads each control's own range instead.
  { printf '<?xml version="1.0" encoding="utf-8"?>\n<mixer enum_mixer_numeric_fallback="true">\n'
    printf '\t<path name="Headphone" />\n\t<path name="InternalMic" />\n\t<path name="Mic" />\n\t<path name="Speaker" />\n'
    n=0; for h; do n=$((n+1)); printf '\t<path name="HDMI%d" />\n' $n; done
    printf '</mixer>\n'; } > "$d/mixer_paths.xml"
  cp "$A/${boards[0]}/volume_curves.xml" "$d/"
  # Google's DSP graph is neutral (speaker pass-through, DC blocker on the mic)
  [ -f "$A/${boards[0]}/dsp.ini" ] && cp "$A/${boards[0]}/dsp.ini" "$d/"
  find "$d" -exec chown -h root:root {} + -exec setfattr -h -n security.selinux -v "$CFG" {} \;
}
# mk <card id> <jack device prefix> <internal mic PCM> [<HDMI PCM>...]: <id> without HDMI, plus
# <id>_hdmi when the card can carry HDMI audio. get_variant_audio picks _hdmi only if the card has
# the first HDMI PCM: e.g. the MSI's PCH card has none (its HDMI is on the NVIDIA card), and an
# HDMI entry pointing at a missing PCM made Android route to nothing once a monitor was plugged.
mk() {
  cfg "$1" "$1" "$2" "$3"
  [ $# -gt 3 ] && cfg "$1_hdmi" "$@"
  return 0
}
mk PCH "HDA Intel PCH" 0 3 7 8 9
mk Intel "HDA Intel" 0
mk Generic "HD-Audio Generic" 0
mk Generic_1 "HD-Audio Generic" 0
mk sofhdadsp sof-hda-dsp 6 3 4 5   # SOF HDA topology: 0 analog, 3-5 HDMI, 6 DMIC

# Kaby Lake Chromebooks on the AVS driver (Pixel Slate): MAX98373 speakers alone on their own
# card, PCM 1. No headphone jack; the DMICs are a separate card (not covered yet). Needs
# snd_intel_dspcfg.dsp_driver=4 on the kernel cmdline. get_variant_audio matches this dir by
# machine driver name, not card ID.
d=$A/avs_max98373; mkdir -p "$d"; ids+=(avs_max98373)
cat > "$d/audio_config.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- Project Churro audio-generic: ALSA card avs_max98373, renamed $W at boot -->
<audio_config>
	<SoundCardName>hw:$W</SoundCardName>
	<HiFi>
		<Speaker>
			<PlaybackPCM>hw:$W,1</PlaybackPCM>
			<DSPLatency>0</DSPLatency>
		</Speaker>
	</HiFi>
</audio_config>
EOF
# MAX98373 amp setup translated 1:1 from the Pixel Slate's working ALSA UCM
# (chromebook-linux-audio, Intel/avs/avs_max98373/Google-Atlas-1.0*.conf):
# top level = UCM BootSequence (amps off, brownout/headroom protection programmed, 0 dB gains,
# DSP gain at 0 dB); Speaker path = UCM EnableSequence (output rail 9.65V, DHT + BDE protection,
# VI sense, amp on). Volume stays in software (HAL).
cat > "$d/mixer_paths.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<mixer enum_mixer_numeric_fallback="true">
	<ctl name="Left DAI Sel Mux" value="Left" />
	<ctl name="Right DAI Sel Mux" value="Right" />
	<ctl name="Left Output Voltage" value="8.60V" />
	<ctl name="Right Output Voltage" value="8.60V" />
	<ctl name="Left Speaker Volume" value="0" />
	<ctl name="Right Speaker Volume" value="0" />
	<ctl name="Left Digital Volume" value="127" />
	<ctl name="Right Digital Volume" value="127" />
	<ctl name="Left DHT Min Volume" value="0" />
	<ctl name="Right DHT Min Volume" value="0" />
	<ctl name="Left DHT Rot Pnt Volume" value="2" />
	<ctl name="Right DHT Rot Pnt Volume" value="2" />
	<ctl name="Left DHT Attack Step Volume" value="0" />
	<ctl name="Right DHT Attack Step Volume" value="0" />
	<ctl name="Left DHT Attack Rate" value="70us" />
	<ctl name="Right DHT Attack Rate" value="70us" />
	<ctl name="Left DHT Release Step Volume" value="0" />
	<ctl name="Right DHT Release Step Volume" value="0" />
	<ctl name="Left DHT Release Rate" value="1150ms" />
	<ctl name="Right DHT Release Rate" value="1150ms" />
	<ctl name="Left BDE LVL1 Thresh" value="120" />
	<ctl name="Right BDE LVL1 Thresh" value="120" />
	<ctl name="Left BDE LVL1 Clip Reduction Volume" value="58" />
	<ctl name="Right BDE LVL1 Clip Reduction Volume" value="58" />
	<ctl name="Left BDE LVL1 Clip Thresh Volume" value="60" />
	<ctl name="Right BDE LVL1 Clip Thresh Volume" value="60" />
	<ctl name="Left BDE LVL1 Limiter Thresh Volume" value="14" />
	<ctl name="Right BDE LVL1 Limiter Thresh Volume" value="14" />
	<ctl name="Left BDE LVL2 Thresh" value="117" />
	<ctl name="Right BDE LVL2 Thresh" value="117" />
	<ctl name="Left BDE LVL2 Clip Reduction Volume" value="58" />
	<ctl name="Right BDE LVL2 Clip Reduction Volume" value="58" />
	<ctl name="Left BDE LVL2 Clip Thresh Volume" value="60" />
	<ctl name="Right BDE LVL2 Clip Thresh Volume" value="60" />
	<ctl name="Left BDE LVL2 Limiter Thresh Volume" value="13" />
	<ctl name="Right BDE LVL2 Limiter Thresh Volume" value="13" />
	<ctl name="Left BDE LVL3 Thresh" value="114" />
	<ctl name="Right BDE LVL3 Thresh" value="114" />
	<ctl name="Left BDE LVL3 Clip Reduction Volume" value="56" />
	<ctl name="Right BDE LVL3 Clip Reduction Volume" value="56" />
	<ctl name="Left BDE LVL3 Clip Thresh Volume" value="60" />
	<ctl name="Right BDE LVL3 Clip Thresh Volume" value="60" />
	<ctl name="Left BDE LVL3 Limiter Thresh Volume" value="12" />
	<ctl name="Right BDE LVL3 Limiter Thresh Volume" value="12" />
	<ctl name="Left BDE LVL4 Thresh" value="112" />
	<ctl name="Right BDE LVL4 Thresh" value="112" />
	<ctl name="Left BDE LVL4 Mute Switch" value="0" />
	<ctl name="Right BDE LVL4 Mute Switch" value="0" />
	<ctl name="Left BDE LVL4 Hold Switch" value="0" />
	<ctl name="Right BDE LVL4 Hold Switch" value="0" />
	<ctl name="Left BDE LVL4 Clip Reduction Volume" value="55" />
	<ctl name="Right BDE LVL4 Clip Reduction Volume" value="55" />
	<ctl name="Left BDE LVL4 Clip Thresh Volume" value="60" />
	<ctl name="Right BDE LVL4 Clip Thresh Volume" value="60" />
	<ctl name="Left BDE LVL4 Limiter Thresh Volume" value="11" />
	<ctl name="Right BDE LVL4 Limiter Thresh Volume" value="11" />
	<ctl name="Left BDE Hold Time" value="100" />
	<ctl name="Right BDE Hold Time" value="100" />
	<ctl name="Left BDE Thresh Hysteresis" value="2" />
	<ctl name="Right BDE Thresh Hysteresis" value="2" />
	<ctl name="Left BDE Attack Rate" value="0" />
	<ctl name="Right BDE Attack Rate" value="0" />
	<ctl name="Left BDE Release Rate" value="5" />
	<ctl name="Right BDE Release Rate" value="5" />
	<ctl name="Left Digital Vol Sel Switch" value="1" />
	<ctl name="Right Digital Vol Sel Switch" value="1" />
	<ctl name="Left Spk Switch" value="0" />
	<ctl name="Right Spk Switch" value="0" />
	<ctl name="Left VI Sense Switch" value="0" />
	<ctl name="Right VI Sense Switch" value="0" />
	<ctl name="Left DHT Switch" value="0" />
	<ctl name="Right DHT Switch" value="0" />
	<ctl name="Left BDE Switch" value="0" />
	<ctl name="Right BDE Switch" value="0" />
	<ctl name="DSP Volume" value="1073741823" />
	<path name="Speaker">
		<ctl name="Left Output Voltage" value="9.65V" />
		<ctl name="Right Output Voltage" value="9.65V" />
		<ctl name="Left DHT Switch" value="1" />
		<ctl name="Right DHT Switch" value="1" />
		<ctl name="Left BDE Switch" value="1" />
		<ctl name="Right BDE Switch" value="1" />
		<ctl name="Left VI Sense Switch" value="1" />
		<ctl name="Right VI Sense Switch" value="1" />
		<ctl name="Left Spk Switch" value="1" />
		<ctl name="Right Spk Switch" value="1" />
	</path>
</mixer>
EOF
cp "$A/${boards[0]}/volume_curves.xml" "$d/"
[ -f "$A/${boards[0]}/dsp.ini" ] && cp "$A/${boards[0]}/dsp.ini" "$d/"
find "$d" -exec chown -h root:root {} + -exec setfattr -h -n security.selinux -v "$CFG" {} \;
# avs_max98373_hdmi: the same plus HDMI/DP. On AVS that's its own card (hdaudioB0D2: PCMs 1-3,
# jacks "hdaudioB0D2 HDMI/DP,pcm=N"), addressed by its ALSA ID since the HAL only renames one
# card; get_variant_audio picks this only when that card exists.
h=$A/avs_max98373_hdmi; rm -rf "$h"; cp -a "$d" "$h"; ids+=(avs_max98373_hdmi)
hd=""; hp=""
for n in 1 2 3; do
  hd+=$(printf '\t\t<HDMI%d>\n\t\t\t<PlaybackPCM>hw:hdaudioB0D2,%d</PlaybackPCM>\n\t\t\t<JackDev>hdaudioB0D2 HDMI/DP,pcm=%d</JackDev>\n\t\t\t<PlaybackChannels>2</PlaybackChannels>\n\t\t</HDMI%d>\n_' $n $n $n $n); hd=${hd%_}
  hp+=$(printf '\t<path name="HDMI%d" />\n_' $n); hp=${hp%_}
done
awk -v x="$hd" '/<\/HiFi>/ { printf "%s", x } { print }' "$d/audio_config.xml" > "$h/audio_config.xml"
awk -v x="$hp" '/^<\/mixer>/ { printf "%s", x } { print }' "$d/mixer_paths.xml" > "$h/mixer_paths.xml"
sed -i 's/ALSA card avs_max98373,/ALSA card avs_max98373 + hdaudioB0D2 (HDMI),/' "$h/audio_config.xml"
find "$h" -exec chown -h root:root {} + -exec setfattr -h -n security.selinux -v "$CFG" {} \;

tr -d '\r' < "$F/get_variant_audio" > "$T/bin/get_variant_audio"   # Windows checkouts: CRLF
chown root:2000 "$T/bin/get_variant_audio"; chmod 0755 "$T/bin/get_variant_audio"
setfattr -n security.selinux -v u:object_r:get_variant_audio_exec:s0 "$T/bin/get_variant_audio"
# churro-mixer: static, like the boot logger. Labelled vendor_toolbox_exec: the label Google's
# policy already lets get_variant_audio execute in its own domain.
${CC:-cc} -static -Os -s -Wall -o "$T/bin/churro-mixer" "$F/churro-mixer.c"
chown root:2000 "$T/bin/churro-mixer"; chmod 0755 "$T/bin/churro-mixer"
setfattr -n security.selinux -v u:object_r:vendor_toolbox_exec:s0 "$T/bin/churro-mixer"

R=$T/etc/init/churro-audio.rc
{ cat <<'EOF'
# Project Churro audio-generic: generic audio HAL config for the PC's sound card
# (/vendor/bin/get_variant_audio picks it; see features/audio-generic)
service vendor.churro.audio /vendor/bin/get_variant_audio
    class core
    user root
    group root audio
    oneshot
    disabled

on boot
    start vendor.churro.audio
EOF
  # one trigger per card, literal paths: init expands ${...} in vendor rc files as vendor_init,
  # which may not read vendor.audio.* (the mount itself runs as init)
  for id in "${ids[@]}"; do
    printf '\non property:vendor.audio.churro.card=%s\n' "$id"
    for b in "${boards[@]}"; do echo "    mount none /vendor/etc/audio/$id /vendor/etc/audio/$b bind"; done
    echo "    restart vendor.audio-hal-aidl"
  done
  for n in 0 1 2 3 4 5 6 7; do
    printf '\non property:vendor.audio.churro.index=%s\n    write /sys/class/sound/card%s/id %s\n' $n $n "$W"
  done; } > "$R"
chown root:root "$R"; chmod 0644 "$R"; setfattr -n security.selinux -v "$CFG" "$R"

V=$(cat "$S/plat_sepolicy_vers.txt")
cat >> "$S/vendor_sepolicy.cil" <<EOF
; Project Churro audio-generic: get_variant_audio reads its configs in /vendor/etc/audio
(allow get_variant_audio vendor_configs_file_$V (dir (search getattr open read)))
(allow get_variant_audio vendor_configs_file_$V (file (getattr open read)))
; churro-audio.rc renames the sound card (write /sys/class/sound/cardN/id runs as vendor_init)
(allow vendor_init_$V sysfs_$V (file (getattr open write)))
; churro-mixer (run by get_variant_audio) unmutes the card: /dev/snd/controlC*
(allow get_variant_audio audio_device_$V (dir (search getattr)))
(allow get_variant_audio audio_device_$V (chr_file (getattr open read write ioctl)))
EOF
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256
echo "   vendor: audio-generic: configs for ${ids[*]} over ${boards[*]}"
