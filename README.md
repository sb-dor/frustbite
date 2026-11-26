# Frustbite

[![CI](https://github.com/sb-dor/frustbite/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/sb-dor/frustbite/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-sb--dor.github.io%2Ffrustbite-informational)](https://sb-dor.github.io/frustbite/)
<!-- Enable after the first pub.dev release; the badge shows "not found" before that.
[![pub package](https://img.shields.io/pub/v/frustbite.svg)](https://pub.dev/packages/frustbite)
-->

**Read and edit audio from pure Dart: info, tags, cover art, waveforms, PCM,
and a lazy editing pipeline with WAV output, powered by a Rust core through FFI
and WebAssembly.**

- Decodes MP3, AAC-LC (M4A, ADTS), ALAC, FLAC, Vorbis, Opus and WAV
- Waveforms (peak or RMS) with bounded memory, even for hour-long files
- Tags and embedded cover art
- Editing in one native call: trim, join with crossfades, mix, fade, normalize,
  resample, mono/stereo, silence trimming and detection; save as 16/24-bit or
  float WAV
- Async: `waveformAsync`, `decodeAsync`, `renderAsync` and friends run on a
  background isolate
- Android, iOS, macOS, Linux, Windows and the web (dart2js and dart2wasm)
- Pure Rust core with no FFmpeg and no C codecs

Read the [documentation](https://sb-dor.github.io/frustbite/) or see the
[package README](packages/frustbite/README.md) for API usage and the
[roadmap](packages/frustbite/README.md#roadmap).

Try it in the minimal [Flutter showcase](packages/showcase/README.md), and see
how it compares with other Dart audio packages in the
[benchmarks](packages/benchmark/README.md).

## Showcase

The [Flutter showcase](packages/showcase/README.md) opens an audio file and
shows its info, tags, cover and waveform (iPhone):

<p align="center">
  <img src="docs/images/showcase-ios.png" alt="frustbite showcase on iPhone: stream info, tags and waveform" width="300">
</p>

## Benchmarks

<img src="packages/benchmark/chart.png" alt="Benchmark chart: frustbite against other Dart audio packages" width="800">

Headline numbers (180 s stereo input, Apple M3 Pro, median of 10 runs):

- Decode WAV: 25.7 ms against 234.9 ms for the pure-Dart `wav` package (9.13x)
- Decode MP3: 98.0 ms against 7964.9 ms for the pure-Dart `glint_audio_pure` (81.29x)
- Decode MP3: 0.91x against `audio_decode` (88.8 ms), which is also native code
- Read and write a WAV: 34.5 ms against 449.7 ms for `wav` (13.04x); resample
  180 s of stereo to 48 kHz: 175.7 ms

Against native C decoders frustbite is roughly on par, and slower on MP3
decode. Methodology and every row are in the
[benchmark README](packages/benchmark/README.md).

## Documentation

```bash
cd docs
npm install
npm run docs:dev
```

Blume builds the production site into `docs/dist/` with
`cd docs && npm run docs:build`.

See [AGENTS.md](AGENTS.md) for the repository layout and development commands.

## License

See [LICENSE](LICENSE). Third-party notices are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md); note that the bundled
`symphonia` decoders are MPL-2.0, and that file says where to get their source.

## Acknowledgements

Repository structure, build hooks and release flow adapted from
[hawkkiller/pixer](https://github.com/hawkkiller/pixer) (MIT, © 2026 Michael
Lazebny).
