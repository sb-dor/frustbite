## 0.0.1

Stage 1: reading.

- `Frustbite.fromFile` and `Frustbite.fromMemory` open an audio source; the
  container is detected from the content and the `format:` hint is advisory.
- `info`, `tags` and `cover`: stream description, metadata tags and embedded
  cover art.
- `waveform` (peak or RMS, merged or per channel) with bounded memory, and
  `decode` to interleaved `f32` PCM, plus `waveformAsync` and `decodeAsync`.
- Formats: MP3, AAC-LC (MP4/M4A, ADTS), ALAC, FLAC, Vorbis, Opus (Ogg and
  WebM/Matroska) and WAV.
- Native: prebuilt libraries for 12 targets, downloaded by a build hook and
  verified by SHA-256; `local_build` and `formats` user defines build from
  source.
- Web: `frustbite.wasm` backend with `Frustbite.initialize`, for JavaScript and
  dart2wasm builds.
- Known limitations: no HE-AAC (explicit SBR throws `UnsupportedFormatException`),
  no Opus in MP4, no tags for WebM, m4a and ADTS `totalFrames` includes AAC priming, ID3v1 text is Latin-1.
- Third-party license notices (including MPL-2.0 symphonia source availability) ship in `THIRD_PARTY_LICENSES.md`.
