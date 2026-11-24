#!/bin/sh
# Generates assets/demo.mp3: 8 s of synthetic plucked notes (decaying sines with
# a slow swell, stereo, 44.1 kHz, CBR 128k). Pure synthesis, released as CC0.
set -eu
cd "$(dirname "$0")/.."
ffmpeg -y -f lavfi -i "aevalsrc=0.8*sin(2*PI*220*pow(2\,mod(floor(t*2)*5\,12)/12)*t)*exp(-5*mod(t\,0.5))*(0.35+0.65*abs(sin(2*PI*0.2*t)))|0.8*sin(2*PI*330*pow(2\,mod(floor(t*2)*7\,12)/12)*t)*exp(-4*mod(t\,0.5))*(0.35+0.65*abs(cos(2*PI*0.2*t))):s=44100:d=8" \
  -af "afade=t=out:st=7:d=1" -c:a libmp3lame -b:a 128k -ar 44100 -ac 2 \
  -map_metadata -1 -id3v2_version 3 \
  -metadata title="frustbite demo" -metadata artist="frustbite" \
  assets/demo.mp3
