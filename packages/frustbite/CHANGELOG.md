## Unreleased

Editing (stage 2).

- `audio.edit()` returns an `AudioEdit`: a lazy, immutable chain of `trim`,
  `gain`, `normalize` (peak, default -1 dBFS), `fadeIn`, `fadeOut`,
  `resample` (FFT resampler, 1 to 768000 Hz), `toMono`, `toStereo`,
  `trimSilence`, `append` (optional equal-power crossfade) and `mix` (gain and
  offset). `Frustbite.concat([...], crossfade: ...)` joins sources. Sources of
  another sample rate or channel count are converted automatically.
- Terminals run the chain in one native call: `render()` (a new `Frustbite`
  held as 32-bit float WAV in memory), `toWav()` and `saveWav(path)`, each with
  an async form on a background isolate.
- WAV output (`WavFormat.pcm16`, `pcm24`, `float32`): `audio.toWav()` and
  `audio.saveWav(path)` also convert any supported format to WAV. `saveWav` is
  unavailable on the web.
- `audio.detectSilence(thresholdDb:, minDuration:)` returns `SilenceRange`s,
  decoding without keeping the PCM; `detectSilenceAsync`.
- ABI version 2 (new exports `frustbite_render`, `frustbite_render_wav`,
  `frustbite_detect_silence`, `frustbite_free_u64`): a library built for 0.0.2
  is refused with a clear `StateError`.
- New Rust dependency: `rubato` 5.1 (MIT OR Apache-2.0) and its pure-Rust
  dependencies. The native libraries grow by about 0.5 MB each.

## 0.0.2

Distribution: the native libraries now ship inside the package.

**Breaking for git-dependency users of 0.0.1.** A git dependency has no
`prebuilt/` directory (the libraries are staged into the published package
only), and the old download of release assets is gone. A git dependency now
needs Rust (the hook builds `../../native/` with cargo); otherwise depend on the
package published on pub.dev. The crate no longer carries a local
`aarch64-linux-gnu-gcc` linker setting in `native/.cargo/config.toml`, so a git
dependency on an arm64 Linux host uses the host's own linker.

- The 12 prebuilt libraries are bundled under `prebuilt/` in the pub archive,
  with a `checksums.json` the build hook verifies (SHA-256). Nothing is
  downloaded at build time; the hook works offline and in locked-down CI.
- One file name per target (`libfrustbite.so`, `libfrustbite.dylib`,
  `frustbite.dll`); the target is only the directory name. A macOS or iOS
  build no longer warns about different framework names per architecture.
- User defines: `source: auto | prebuilt | build | none` (a map per OS is
  accepted), `library: <path>` for your own build, and `formats` / `local_build`
  (both mean `source: build`). A typo is an error, never a silent default.
- Source builds work from pub.dev too: the package carries the Rust crate in
  `rust/` and the hook falls back to `cargo build --locked` when no bundled
  library fits, or when `source: build` is set. Cargo is found in
  `~/.cargo/bin` even when it is not on `PATH`.
- `library: <path>` is unchecked (no checksum, no build-time ABI check; the
  runtime ABI check still runs at the first call), a relative path resolves
  against the pubspec that sets it, and combining it with `formats` is an
  error.
- Linux libraries are built with `cargo zigbuild` against glibc 2.17 (was: the
  CI runner's glibc 2.35), so they load on older distributions.
- `build.rs` sets the link flags: 16 KB page alignment on Android, a
  relocatable `@rpath` install name with header padding on Apple platforms, a
  static libgcc on Linux, and a static C runtime on Windows (no VC++
  redistributable needed).
- Every library is verified before release: only `frustbite_*` exports,
  Android alignment, the glibc floor, allowed Linux dependencies, the Apple
  install name and minimum OS, and no VC++ runtime import on Windows.

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
