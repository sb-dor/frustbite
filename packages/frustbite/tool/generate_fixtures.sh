#!/usr/bin/env bash
# Generates the audio fixtures in test/fixtures from synthetic signals.
# Dev-only tool: assumes macOS + Homebrew ffmpeg (needs afconvert for
# HE-AAC, and python3). Idempotent: re-running overwrites every fixture.
# The encoders are not guaranteed bit-exact across ffmpeg versions, so a rerun may
# change the bytes of the other fixtures; tone.aac was added later and was
# generated alone with the ADTS line below.
set -euo pipefail

FFMPEG="${FFMPEG:-ffmpeg}"
for tool in "$FFMPEG" ffprobe afconvert python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required tool '$tool' not found in PATH" >&2
    exit 1
  }
done
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../test/fixtures"
mkdir -p "$out"
cd "$out"

trap 'rm -f cover.png' EXIT

ff() { "$FFMPEG" -hide_banner -loglevel error -y "$@"; }

# 3 s stereo: L = 440 Hz, R = 880 Hz, amplitude 0.5, 44.1 kHz s16.
SRC=(-f lavfi -i "aevalsrc=0.5*sin(2*PI*440*t)|0.5*sin(2*PI*880*t):s=44100:d=3")
TAGS=(-metadata title="frustbite tone" -metadata artist=frustbite
  -metadata album=fixtures -metadata date=2026 -metadata track=1/1
  -metadata genre=Test)

# 64x64 blue PNG cover.
ff -f lavfi -i "color=c=blue:s=64x64:d=1" -frames:v 1 cover.png

# Vorbis-comment cover: base64 of a FLAC PICTURE block (front cover, PNG).
PIC_B64="$(python3 -I - <<'PY'
import base64, struct
d = open("cover.png", "rb").read()
m = b"image/png"
b = (struct.pack(">II", 3, len(m)) + m + struct.pack(">I", 0)
     + struct.pack(">IIIII", 64, 64, 24, 0, len(d)) + d)
print(base64.b64encode(b).decode())
PY
)"

COVER=(-i cover.png -map 0:a -map 1:v -disposition:v:0 attached_pic)

# WAV
ff "${SRC[@]}" -c:a pcm_s16le tone.wav
ff "${SRC[@]}" -map_metadata -1 -fflags +bitexact -c:a pcm_s16le notags.wav
ff -f lavfi -i "aevalsrc=0.8*sin(2*PI*1000*t)*exp(-60*t):s=44100:d=0.05" \
  -ac 1 -c:a pcm_s16le click.wav

# MP3
ff "${SRC[@]}" "${COVER[@]}" "${TAGS[@]}" -c:a libmp3lame -b:a 128k \
  -id3v2_version 4 -c:v copy tone.mp3
ff "${SRC[@]}" -c:a libmp3lame -q:a 4 -write_xing 0 -id3v2_version 0 \
  tone_vbr_noxing.mp3
# Truncated: first 60 % of tone.mp3.
size=$(wc -c < tone.mp3 | tr -d ' ')
head -c $((size * 60 / 100)) tone.mp3 > truncated.mp3

# ID3v1-only MP3 with a CP1251 title (Привет = CF F0 E8 E2 E5 F2).
ff "${SRC[@]}" -c:a libmp3lame -b:a 64k -write_xing 0 -id3v2_version 0 \
  -map_metadata -1 id3v1_cp1251.mp3
python3 -I - <<'PY'
title = "Привет".encode("cp1251")
tag = (b"TAG" + title.ljust(30, b"\0") + b"frustbite".ljust(30, b"\0")
       + b"fixtures".ljust(30, b"\0") + b"2026" + b"\0" * 28 + b"\0\x01" + bytes([255]))  # v1.1 track 1
assert len(tag) == 128
with open("id3v1_cp1251.mp3", "ab") as f:
    f.write(tag)
PY

# M4A
ff "${SRC[@]}" "${COVER[@]}" "${TAGS[@]}" -c:a aac -b:a 128k -c:v copy \
  -movflags +faststart tone.m4a
# HE-AAC: ffmpeg's aac_at has no profile option, so use macOS afconvert.
afconvert -f m4af -d aach -b 64000 tone.wav tone_he.m4a
ff "${SRC[@]}" -c:a alac tone_alac.m4a

# ADTS AAC-LC (raw .aac stream, no container metadata).
ff "${SRC[@]}" -c:a aac -b:a 128k -f adts tone.aac

# FLAC
ff "${SRC[@]}" "${COVER[@]}" "${TAGS[@]}" -c:a flac -c:v copy tone.flac
ff -f lavfi -i "anullsrc=r=44100:cl=stereo" -t 1 -c:a flac silence.flac

# Ogg Vorbis (libvorbis if present, else the native experimental encoder)
if "$FFMPEG" -hide_banner -encoders 2>/dev/null | grep -q libvorbis; then
  ff "${SRC[@]}" "${TAGS[@]}" -metadata METADATA_BLOCK_PICTURE="$PIC_B64" -c:a libvorbis -q:a 3 tone.ogg
else
  ff "${SRC[@]}" "${TAGS[@]}" -metadata METADATA_BLOCK_PICTURE="$PIC_B64" -c:a vorbis -strict -2 -b:a 128k tone.ogg
fi

# Opus in Ogg (48 kHz)
ff "${SRC[@]}" "${TAGS[@]}" -metadata METADATA_BLOCK_PICTURE="$PIC_B64" -ar 48000 -c:a libopus -b:a 96k tone.opus

# Opus in WebM, written to a pipe so the muxer cannot seek back and fill in
# the Duration element (like MediaRecorder output).
"$FFMPEG" -hide_banner -loglevel error -y "${SRC[@]}" -ar 48000 \
  -c:a libopus -b:a 96k -f webm pipe:1 > tone.webm

# 4 KiB of deterministic pseudo-random bytes.
python3 -I -c '
import random
random.seed(42)
open("corrupt.bin", "wb").write(bytes(random.getrandbits(8) for _ in range(4096)))
'

echo "fixtures written to $out"
