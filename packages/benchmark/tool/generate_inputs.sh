#!/usr/bin/env bash
# Generates the benchmark inputs in ../inputs (gitignored): a 180 s, 44.1 kHz
# stereo "music-like" signal (chord tones + pink noise + beat envelope) as
# mp3 (CBR 192k, ID3 tags, 500x500 JPEG cover), ogg (Vorbis), flac and wav.
# Needs ffmpeg with libmp3lame; override the binary with FFMPEG=/path.
set -euo pipefail

FFMPEG="${FFMPEG:-ffmpeg}"
command -v "$FFMPEG" >/dev/null 2>&1 || {
  echo "error: '$FFMPEG' not found in PATH" >&2
  exit 1
}
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../inputs"
mkdir -p "$out"
cd "$out"
ff() { "$FFMPEG" -hide_banner -loglevel error -y "$@"; }

DUR=180
# Am - F - C - G, one chord per 4.5 s (root, third, fifth plus an octave).
# Left and right use slightly detuned copies so the channels differ.
# A 2 Hz beat envelope (120 BPM) gates the tones; pink noise sits underneath.
chord='lt(mod(t,18),4.5)*(sin(2*PI*220*t)+sin(2*PI*261.63*t)+sin(2*PI*329.63*t))
 +between(mod(t,18),4.5,9)*(sin(2*PI*174.61*t)+sin(2*PI*220*t)+sin(2*PI*261.63*t))
 +between(mod(t,18),9,13.5)*(sin(2*PI*261.63*t)+sin(2*PI*329.63*t)+sin(2*PI*392*t))
 +gte(mod(t,18),13.5)*(sin(2*PI*196*t)+sin(2*PI*246.94*t)+sin(2*PI*293.66*t))'
beat='(0.55+0.45*pow(abs(sin(PI*2*t)),4))'
chord="${chord//$'\n'/}"
right="${chord//220/220.7}"
tones="aevalsrc='0.12*(${chord})*${beat}|0.12*(${right})*${beat}':s=44100:d=${DUR}"
noise="anoisesrc=color=pink:amplitude=0.08:sample_rate=44100:duration=${DUR}:seed=7"

ff -f lavfi -i "$tones" -f lavfi -i "$noise" \
  -filter_complex "[1:a]aformat=channel_layouts=stereo[n];[0:a][n]amix=inputs=2:normalize=0,alimiter=limit=0.9" \
  -c:a pcm_s16le music.wav
ff -i music.wav -c:a flac music.flac
ff -i music.wav -c:a vorbis -strict -2 -b:a 192k music.ogg

# 500x500 JPEG cover.
ff -f lavfi -i "testsrc2=s=500x500:d=1" -frames:v 1 -q:v 3 cover.jpg

ff -i music.wav -i cover.jpg -map 0:a -map 1:v -c:a libmp3lame -b:a 192k \
  -c:v copy -id3v2_version 3 -disposition:v attached_pic \
  -metadata title="Benchmark Tone" -metadata artist="frustbite" \
  -metadata album="Benchmarks" -metadata date=2026 -metadata genre=Test \
  -metadata track=1/1 music.mp3

ls -l music.mp3 music.ogg music.flac music.wav cover.jpg
