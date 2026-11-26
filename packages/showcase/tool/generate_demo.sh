#!/bin/sh
# Generates assets/demo.mp3: 8 s of synthetic plucked notes (decaying sines with
# a slow swell, stereo, 44.1 kHz, CBR 128k), with ID3 tags and a cover drawn from
# its own waveform. Pure synthesis, released as CC0.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ffmpeg -hide_banner -loglevel error -y -f lavfi -i "aevalsrc=0.8*sin(2*PI*220*pow(2\,mod(floor(t*2)*5\,12)/12)*t)*exp(-5*mod(t\,0.5))*(0.35+0.65*abs(sin(2*PI*0.2*t)))|0.8*sin(2*PI*330*pow(2\,mod(floor(t*2)*7\,12)/12)*t)*exp(-4*mod(t\,0.5))*(0.35+0.65*abs(cos(2*PI*0.2*t))):s=44100:d=8" \
  -af "afade=t=out:st=7:d=1" "$tmp/demo.wav"

# Cover: the waveform in white on a teal-to-blue gradient, 600x600 JPEG.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "gradients=s=600x600:c0=0x0f766e:c1=0x1e3a8a:x0=0:y0=0:x1=600:y1=600:d=1:r=1" \
  -i "$tmp/demo.wav" \
  -filter_complex "[1:a]aformat=channel_layouts=mono,showwavespic=s=520x260:colors=white:scale=sqrt[w];[0:v][w]overlay=40:170,format=yuvj420p" \
  -frames:v 1 "$tmp/cover.jpg"

ffmpeg -hide_banner -loglevel error -y -i "$tmp/demo.wav" -i "$tmp/cover.jpg" \
  -map 0:a -map 1:v -c:a libmp3lame -b:a 128k -ar 44100 -ac 2 -c:v copy \
  -disposition:v attached_pic -metadata:s:v title="Cover" -metadata:s:v comment="Cover (front)" \
  -map_metadata -1 -id3v2_version 3 \
  -metadata title="frustbite demo" -metadata artist="frustbite" \
  -metadata album="Showcase" -metadata genre="Electronic" -metadata date="2026" \
  assets/demo.mp3
