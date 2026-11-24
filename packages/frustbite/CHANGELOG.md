## 0.0.2

Distribution: the native libraries now ship inside the package.

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
