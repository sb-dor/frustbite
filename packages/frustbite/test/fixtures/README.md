# Test fixtures

Audio fixtures for the Rust and Dart tests. Every file is generated from
synthetic signals (sine tones, a decaying click, silence, seeded random
bytes) and is released under CC0 1.0 (public domain).

Regenerate with:

```sh
packages/frustbite/tool/generate_fixtures.sh
```

The script is a dev-only tool (macOS + Homebrew `ffmpeg`, plus `afconvert`
and `python3`); ffmpeg does not ship with the package. The native Vorbis
encoder (`vorbis -strict -2`) is used when `libvorbis` is missing.

| File | Content |
|---|---|
| `tone.wav` | 3.0 s, 44.1 kHz, stereo, s16; L = 440 Hz, R = 880 Hz, amplitude 0.5 |
| `tone.mp3` | same signal, CBR 128 kbps, ID3v2.4 tags + cover |
| `tone_vbr_noxing.mp3` | VBR, no Xing/Info header, no tags |
| `tone.m4a` | AAC-LC 128 kbps, MP4 tags + cover |
| `tone.aac` | AAC-LC 128 kbps in raw ADTS, no tags |
| `tone_he.m4a` | HE-AAC (made with `afconvert`), for the unsupported test |
| `tone_alac.m4a` | ALAC |
| `tone.flac` | FLAC, Vorbis comments + cover |
| `tone.ogg` | Vorbis, Vorbis comments |
| `tone.opus` | Opus in Ogg, 48 kHz, comments |
| `tone.webm` | Opus in WebM, no duration in the header (like MediaRecorder) |
| `click.wav` | 50 ms, mono, 44.1 kHz |
| `silence.flac` | 1.0 s digital silence |
| `id3v1_cp1251.mp3` | ID3v1.1 tag only; title bytes are CP1251 for "Привет" |
| `notags.wav` | no metadata |
| `truncated.mp3` | `tone.mp3` cut at 60 % of its bytes |
| `corrupt.bin` | 4 KiB of random bytes, `random.seed(42)` |

Tagged files carry title `frustbite tone`, artist `frustbite`, album
`fixtures`, year 2026, track 1/1, genre `Test`. MP3, M4A, FLAC, Ogg Vorbis
and Opus also carry a 64x64 blue PNG cover (attached picture; for Ogg/Opus a
`METADATA_BLOCK_PICTURE` Vorbis comment). `tone_he.m4a`, `tone_alac.m4a`,
`tone_vbr_noxing.mp3`, `tone.aac` and `tone.webm` are untagged.
