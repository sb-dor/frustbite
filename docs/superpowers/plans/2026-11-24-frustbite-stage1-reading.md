# frustbite Stage 1 (scaffold + reading) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pixer-style monorepo where the `frustbite` Dart package reads any supported audio file on all 12 native targets and in the browser (wasm): info, tags + cover, waveform, PCM decode (sync + async). The repo also has benchmarks, a showcase app, a docs site, CI, and a first prebuilt-asset release.

**Architecture:** A Rust crate (`native/`) exposes a C ABI (cbindgen → `frustbite.h` → ffigen `@Native` bindings). The Dart package loads it through build hooks: download a prebuilt binary and verify its hash, or build it from source with `native_toolchain_rust`. The web backend calls the same exports from `frustbite.wasm` through `dart:js_interop`. Everything runs in one native call per terminal; sources stay encoded and are decoded in a streaming fashion.

**Tech Stack:** Rust 1.90+ (symphonia 0.6, lofty 0.25, a pure-Rust opus decoder, serde_json), Dart 3.10+ (`hooks`, `code_assets`, `native_toolchain_rust`, `ffi`, `ffigen`, `crypto`, `test`, `benchmark_harness`), Flutter (showcase), Blume (docs), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-24-frustbite-design.md` (approved 2026-11-24). Model project: https://github.com/hawkkiller/pixer (MIT). Mirror its structure and conventions, but write our own code; do not copy files verbatim.

**Scope:** Spec stage 1 only. Stages 2–5 (editing, encoding, streaming/CLI, pub.dev publish) get their own plans. Stage 1 does not publish to pub.dev; it ends at `dart pub publish --dry-run`.

## Global Constraints

- Pure Dart package; no Flutter-plugin structure, no platform channels or pigeon.
- **Pure Rust only.** No C decoders added for speed. Every dependency must build for `wasm32-unknown-unknown`.
- Dependency licenses: MIT, Apache-2.0, BSD, Zlib or MPL-2.0 only. No GPL or LGPL.
- Project license: MIT.
- Targets: android arm/arm64/x64, ios arm64 + simulator arm64/x64, linux arm64/x64, macos arm64/x64, windows arm64/x64, plus `frustbite.wasm`.
- Repo: `github.com/sb-dor/frustbite` (public). Asset release tag: `frustbite-assets-vX.Y.Z`, equal to the package version. First version `0.0.1`.
- **Every `git push`, `gh repo create`, tag push and release needs the author's explicit OK in chat at that moment.** Local commits are fine.
- Read formats: mp3, aac/m4a (AAC-LC only), alac, flac, vorbis/ogg, opus (Ogg and WebM/Matroska), wav. HE-AAC/HE-AACv2 → `UnsupportedFormatException`.
- Cargo features per codec: `mp3`, `aac`, `alac`, `flac`, `vorbis`, `opus`, `wav`, all on by default. User define `hooks.user_defines.frustbite.formats` forces a source build with only those.
- Web: byte API only. `fromFile` throws `UnsupportedError`. `Frustbite.initialize()` fetches `frustbite.wasm` relative to the page, or takes `wasmUri` / `wasmBytes`. The user places the wasm file manually (as in pixer).
- Memory: `info`, `tags`, `waveform` stream packet by packet. A waveform of a 1-hour file must stay within ~50 MB RSS above baseline.
- Never edit generated files (`lib/src/bindings/bindings.dart`, `native/include/frustbite.h`). Regenerate them with `dart tool/generate_bindings.dart`.
- Before adding any pub package or crate, check its latest version and status on pub.dev / crates.io and use the latest stable.
- Release profile: `opt-level=3`, `lto="fat"`, `codegen-units=1`, `panic="abort"`, `strip=true`.

## Review Focus

1. **Truncated or corrupt files** (download cut off, wrong extension). Expect `DecodingException` or a partial result, never a crash or hang. Test: Task 4 `decode_truncated_mp3_returns_error_or_partial`, Task 8 `corrupt bytes throw DecodingException`.
2. **Files without a duration in the header** (VBR mp3 without Xing, raw ogg, webm from MediaRecorder). Expect `info.duration` to be computed by scanning, and waveform buckets to still cover the whole file. Test: Task 4 `info_scans_duration_when_header_missing`, Task 6 `waveform_covers_file_without_duration`.
3. **Very short files and more buckets than frames** (a 50 ms click with `buckets: 1000`). Expect exactly `buckets` values with no NaN. Test: Task 6 `waveform_more_buckets_than_frames`.
4. **Using a disposed object, or disposing during an async call.** Expect `StateError`, never a use-after-free. Test: Task 9 `dispose during waveformAsync throws StateError and does not crash`.
5. **Non-UTF-8 or odd tags** (ID3v1 Latin-1/CP1251 Cyrillic titles, empty frames, huge cover art). Expect a readable or `null` title, never an exception. Test: Task 7 `tags_latin1_id3v1_title`, Task 7 `tags_missing_returns_empty`.

---

## File Structure

```
frustbite/
├─ pubspec.yaml                    workspace root (packages/frustbite, packages/benchmark); user_defines local_build: true
├─ .gitignore, LICENSE, README.md, AGENTS.md
├─ scripts/build.sh                build all native targets available on host
├─ native/
│  ├─ Cargo.toml, Cargo.lock, rust-toolchain.toml, cbindgen.toml, .cargo/config.toml
│  ├─ README.md, RESEARCH.md
│  ├─ tests/fixtures/ -> ../../packages/frustbite/test/fixtures (Rust tests read the same files)
│  └─ src/
│     ├─ lib.rs                    module wiring, abi version
│     ├─ error.rs                  FrustbiteErrorCode + From impls
│     ├─ source.rs                 AudioSource (memory Arc<[u8]> | file path), MediaSourceStream factory
│     ├─ probe.rs                  format/codec detection, AudioInfo, duration scan
│     ├─ codecs.rs                 symphonia CodecRegistry incl. opus adapter, feature gating
│     ├─ opus.rs                   symphonia Decoder impl over the chosen pure-Rust opus crate
│     ├─ decode.rs                 full decode to interleaved f32
│     ├─ waveform.rs               streaming peak/rms summary
│     ├─ tags.rs                   lofty → TagsJson + cover
│     ├─ ffi.rs                    extern "C" surface, out-params, buffer free
│     └─ wasm_alloc.rs             frustbite_alloc / frustbite_dealloc (cfg wasm32)
├─ packages/frustbite/
│  ├─ pubspec.yaml, README.md, CHANGELOG.md, LICENSE, .pubignore, .gitignore, analysis_options.yaml
│  ├─ hook/build.dart
│  ├─ native/include/frustbite.h   generated
│  ├─ lib/frustbite.dart           public exports
│  ├─ lib/src/
│  │  ├─ frustbite_base.dart       Frustbite class (shared API, dispose guard, busy counter)
│  │  ├─ audio_info.dart, audio_tags.dart, audio_pcm.dart, waveform.dart, enums.dart
│  │  ├─ frustbite_exception.dart  exceptions + checkError(code)
│  │  ├─ abi.dart                  frustbiteAbiVersion + checkFrustbiteAbi
│  │  ├─ backend.dart              conditional export of backend_native / web/backend_web
│  │  ├─ backend_native.dart       FFI calls, NativeFinalizer, Isolate.run async
│  │  ├─ bindings/bindings.dart    generated
│  │  ├─ web/backend_web.dart, web/wasm_runtime.dart
│  │  └─ hook/ targets.dart, version.dart, hashes.dart, download_asset.dart, local_build.dart, get_android_compiler_config.dart, target_versions.dart
│  ├─ tool/ build.dart, build_wasm.dart, generate_bindings.dart, generate_asset_hashes.dart, generate_fixtures.sh, memory_check.dart
│  ├─ example/frustbite_example.dart
│  └─ test/ fixtures/, frustbite_test.dart, frustbite_file_test.dart, frustbite_async_test.dart, frustbite_wasm_test.dart, hook_test.dart
├─ packages/benchmark/             bin/main.dart, lib/*_benchmark.dart, tool/generate_inputs.sh, chart.html, README.md
├─ packages/showcase/              Flutter app (not in workspace list, like pixer)
├─ docs/                           Blume site: package.json, blume.config.ts, content/*.mdx
└─ .github/workflows/ build_release.yaml, docs.yaml
```

---

### Task 0: Toolchain prerequisites

**Files:** none

- [ ] **Step 1: Ask the author** to install Rust. In chat, show `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh` and ask them to run it themselves, or to approve that you run it. Wait for confirmation.
- [ ] **Step 2: Verify.** Run `cargo --version && rustup --version`. Expected: both print versions.
- [ ] **Step 3:** Run `git init -b main` in `/Users/avaz/StudioProjects/frustbite`. Commit the existing `docs/superpowers/` (spec + this plan) with message `docs: add frustbite design and stage 1 plan`.

### Task 1: Workspace skeleton + ABI round trip

The smallest end-to-end slice: Rust crate → header → bindings → hook (source build) → Dart test calls `frustbite_abi_version`.

**Files:**
- Create: root `pubspec.yaml`, `.gitignore`, `LICENSE` (MIT, "Copyright (c) 2026 sb-dor"), `README.md` (stub), `AGENTS.md`
- Create: `native/Cargo.toml`, `native/rust-toolchain.toml`, `native/cbindgen.toml`, `native/.cargo/config.toml`, `native/src/lib.rs`, `native/src/ffi.rs`, `native/src/error.rs`, `native/src/wasm_alloc.rs`
- Create: `packages/frustbite/pubspec.yaml`, `hook/build.dart`, `lib/src/hook/local_build.dart`, `lib/src/abi.dart`, `lib/src/bindings/bindings.dart` (generated), `native/include/frustbite.h` (generated), `tool/generate_bindings.dart`, `lib/frustbite.dart`, `test/frustbite_test.dart`

**Interfaces:**
- Produces (Rust, C ABI): `uint32_t frustbite_abi_version(void)` returning `FRUSTBITE_ABI_VERSION = 1`.
- Produces (Rust): `#[repr(u32)] enum FrustbiteErrorCode { Success=0, InvalidPath=1, UnsupportedFormat=2, DecodingError=3, IoError=4, InvalidPointer=5, InvalidParameter=6, Unknown=99 }`. Code 7 is reserved for `EncodingError` in stage 3.
- Produces (Rust, wasm32 only): `frustbite_alloc(size: usize, align: usize) -> *mut u8` and `frustbite_dealloc(ptr, size, align)`. Excluded from cbindgen.
- Produces (Dart): `const frustbiteAbiVersion = 1;` and `void checkFrustbiteAbi(int actual)`, which throws `StateError` on mismatch.
- Produces (Dart hook): `const supportedFormats = {'aac','alac','flac','mp3','opus','vorbis','wav'}`, `List<String>? readFormats(HookInput input)`, `Future<void> runLocalBuild(BuildInput, BuildOutputBuilder, {List<String>? formats})`. The asset name is `'src/bindings/bindings.dart'` and the crate path is `'../../native'`.

- [ ] **Step 1:** Write the Cargo manifest: crate `frustbite`, edition 2024, `crate-type = ["staticlib","cdylib"]`, the features list from Global Constraints, and the release profile. Pin `rust-toolchain.toml` to channel 1.90.0 (or newer stable) with all 12 native targets + `wasm32-unknown-unknown`. In `.cargo/config.toml`, set the Android `max-page-size=16384` flags and the aarch64-linux linker, as pixer does.
- [ ] **Step 2: Write the failing Rust test** `abi_version_is_one` in `native/src/lib.rs`: `assert_eq!(frustbite_abi_version(), 1)`.
- [ ] **Step 3:** Run `cd native && cargo test`. Expected: FAIL (function missing).
- [ ] **Step 4:** Implement `frustbite_abi_version`, the error enum, and `wasm_alloc.rs`. Configure `cbindgen.toml`: language C, include guard `FRUSTBITE_H`, exclude the alloc/dealloc functions, and include the enums that no signature references.
- [ ] **Step 5:** Run `cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --check`. Expected: PASS.
- [ ] **Step 6:** Write `tool/generate_bindings.dart`: run `cbindgen` into `native/include/frustbite.h`, then run ffigen with `@Native` (ffi-native) output to `lib/src/bindings/bindings.dart`, using asset id `package:frustbite/src/bindings/bindings.dart`. Enums shared with web (`FrustbiteErrorCode`, later the codec/container enums) are hidden from the bindings and redefined in `lib/src/enums.dart` (pixer's `_sharedEnums` pattern). Install `cbindgen` with `cargo install cbindgen`.
- [ ] **Step 7: Write the failing Dart test** `test/frustbite_test.dart`: `test('native ABI matches package', () => expect(Frustbite.abiVersion, frustbiteAbiVersion));`.
- [ ] **Step 8:** Write the root workspace `pubspec.yaml` (`sdk: ^3.10.0`, workspace `packages/frustbite`, `hooks.user_defines.frustbite.local_build: true`). Write the package pubspec: `name: frustbite`, `version: 0.0.1`, `repository: https://github.com/sb-dor/frustbite`, `resolution: workspace`. Write `hook/build.dart`, which for now always calls `runLocalBuild`, and a temporary `static int get abiVersion` on a minimal `Frustbite` class.
- [ ] **Step 9:** Run `cd packages/frustbite && dart test test/frustbite_test.dart`. Expected: PASS (the hook builds the crate from source).
- [ ] **Step 10:** Write `AGENTS.md`: repo map, commands (cargo test/clippy/fmt, generate_bindings, dart test, wasm tests, benchmarks), the "never edit generated files" rule, and the ABI-bump rule (bump the Rust and Dart constants together). Commit `chore: scaffold workspace, native crate and ABI check`.

### Task 2: Test fixtures

**Files:**
- Create: `packages/frustbite/tool/generate_fixtures.sh`, `packages/frustbite/test/fixtures/*`, `packages/frustbite/test/fixtures/README.md`
- Create: symlink `native/tests/fixtures` → `../../packages/frustbite/test/fixtures`

**Interfaces:**
- Produces: the fixture set every later test uses. All files are generated from synthetic signals and are CC0 (the README says so and records the generator command). ffmpeg is a dev-only tool here and does not ship.

| File | Content |
|---|---|
| `tone.wav` | 3.0 s, 44100 Hz, stereo, s16, L=440 Hz sine, R=880 Hz sine, amplitude 0.5 |
| `tone.mp3` | same signal, CBR 128 kbps, ID3v2.4 tags + cover |
| `tone_vbr_noxing.mp3` | same signal, VBR, Xing header stripped (`-write_xing 0`) |
| `tone.m4a` | AAC-LC 128 kbps, MP4 tags + cover |
| `tone_he.m4a` | HE-AAC (`aac_at -profile:a aac_he`), for the unsupported test |
| `tone_alac.m4a` | ALAC |
| `tone.flac` | FLAC, Vorbis comments + cover |
| `tone.ogg` | Vorbis (`libvorbis` if available, else `vorbis -strict -2`), Vorbis comments |
| `tone.opus` | Opus in Ogg, 48 kHz |
| `tone.webm` | Opus in WebM, no duration in header (as MediaRecorder writes it) |
| `click.wav` | 50 ms, mono, 44100 Hz |
| `silence.flac` | 1.0 s digital silence |
| `id3v1_cp1251.mp3` | ID3v1 only, title bytes = CP1251 for "Привет" |
| `notags.wav` | no metadata |
| `truncated.mp3` | `tone.mp3` cut at 60 % of its bytes |
| `corrupt.bin` | 4 KiB of random bytes, fixed seed |

All tagged files carry title `frustbite tone`, artist `frustbite`, album `fixtures`, year 2026, track 1/1, genre `Test`, and a 64×64 PNG cover (generated by ffmpeg `color=c=blue`).

- [ ] **Step 1:** Write `generate_fixtures.sh` (idempotent, `set -euo pipefail`). Run it and check that every file exists and that `ffprobe` reports the expected codec for each.
- [ ] **Step 2:** Commit the fixtures and the script: `test: add generated CC0 audio fixtures`.

### Task 3: Opus crate research

**Files:**
- Create: `native/RESEARCH.md`

- [ ] **Step 1:** Compare `opus-decoder` and `ropus` (and any newer pure-Rust candidate) on four points: decoding the official Opus test vectors (https://opus-codec.org/testvectors/) within their conformance tolerance; decode speed on `tone.opus` × 100; a `cargo build --target wasm32-unknown-unknown` check; and whether an encoder exists (this matters for stage 3). Also record symphonia 0.6's support for opus codec params in its Ogg and MKV readers.
- [ ] **Step 2:** Write `RESEARCH.md` with the table, the decision and the reasoning. Commit `docs: research pure-Rust opus decoders`.

### Task 4: Source, probe and info

**Files:**
- Create: `native/src/source.rs`, `native/src/probe.rs`, `native/src/codecs.rs`, `native/src/opus.rs`
- Modify: `native/src/ffi.rs`, `native/src/lib.rs`

**Interfaces:**
- Produces (Rust): `enum AudioSource { Memory(Arc<[u8]>), File(PathBuf) }`. Each operation opens a fresh `MediaSourceStream`, so a handle is immutable and `Send + Sync`.
- Produces (C ABI):
  - `#[repr(u32)] enum FrustbiteContainer { Mp3=0, Mp4=1, Flac=2, Ogg=3, Wav=4, Mkv=5, Adts=6 }` and `const FRUSTBITE_FORMAT_DETECT: u32 = u32::MAX`
  - `#[repr(u32)] enum FrustbiteCodec { Mp3=0, Aac=1, Alac=2, Flac=3, Vorbis=4, Opus=5, Pcm=6 }`
  - `#[repr(C)] struct FrustbiteAudioInfo { container: u32, codec: u32, sample_rate: u32, channels: u32, bits_per_sample: u32 /*0 = n/a*/, bitrate: u32 /*bps, 0 = unknown*/, total_frames: u64, duration_us: u64 }`
  - `FrustbiteErrorCode frustbite_open_memory(const uint8_t* data, size_t len, uint32_t format, FrustbiteAudio** out)` (copies the bytes)
  - `FrustbiteErrorCode frustbite_open_file(const char* utf8_path, uint32_t format, FrustbiteAudio** out)` (not exported on wasm). Both probe immediately and fail fast on unsupported or corrupt input.
  - `void frustbite_free(FrustbiteAudio*)`
  - `FrustbiteErrorCode frustbite_get_info(const FrustbiteAudio*, FrustbiteAudioInfo* out)`, cached after the first call
  - `size_t frustbite_source_byte_length(const FrustbiteAudio*)` (for the finalizer's externalSize)
- Opus is registered as a symphonia `Decoder` in `codecs.rs` via `opus.rs`, gated by the `opus` feature.

- [ ] **Step 1: Write the failing Rust tests** in `probe.rs`:
  - `info_wav`: Pcm, Wav, 44100, 2, 16 bits, total_frames 132300, duration_us 3_000_000.
  - `info_each_supported_fixture` (table-driven): codec and container for every supported fixture; `abs(duration_us - 3_000_000) < 50_000`.
  - `info_opus_is_48k`: tone.opus and tone.webm report 48000 Hz.
  - `info_scans_duration_when_header_missing`: tone.webm and tone_vbr_noxing.mp3 within 50 ms of 3 s.
  - `open_he_aac_is_unsupported`: `UnsupportedFormat`.
  - `open_corrupt_is_unsupported_or_decoding_error`: one of those two codes.
  - `decode_truncated_mp3_returns_error_or_partial` lives in Task 5; here, check that `open` on truncated.mp3 succeeds.
  - `open_null_pointer_is_invalid_pointer`.
  - `open_missing_file_is_invalid_path`.
- [ ] **Step 2:** Run `cargo test probe`. Expected: FAIL.
- [ ] **Step 3:** Implement. When `n_frames` is missing, scan packet timestamps to the end without decoding and cache the result. Format hints map container → symphonia `Hint` extension. The FFI layer wraps every body in `catch_unwind` → `Unknown`.
- [ ] **Step 4:** Run `cargo test && cargo clippy --all-targets -- -D warnings`, then `cargo clippy --no-default-features --features wav -- -D warnings`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(native): open sources and probe audio info`.

### Task 5: Full decode to PCM

**Files:**
- Create: `native/src/decode.rs`
- Modify: `native/src/ffi.rs`

**Interfaces:**
- Produces (C ABI): `FrustbiteErrorCode frustbite_decode(const FrustbiteAudio*, float** out_samples, size_t* out_len /*samples, interleaved*/, uint32_t* out_sample_rate, uint32_t* out_channels)` and `void frustbite_free_f32(float* ptr, size_t len)`.
- Output: interleaved f32 in [-1, 1], native sample rate, native channel count. No resampling in stage 1.

- [ ] **Step 1: Write the failing tests:**
  - `decode_wav_exact`: len = 132300 × 2. The sample at frame 100, left channel, equals `0.5*sin(2π·440·100/44100)` within 1/32768.
  - `decode_lossy_fixtures_have_tone`: for mp3/m4a/ogg/opus, a Goertzel-filter energy check shows the left channel dominant at 440 Hz and the right at 880 Hz.
  - `decode_flac_matches_wav`: bit-exact with `tone.wav`'s samples.
  - `decode_truncated_mp3_returns_error_or_partial`: Ok with ≥ 1.5 s of frames, or `DecodingError`. Never a panic.
  - `decode_silence_is_zero`: all samples == 0.0.
- [ ] **Step 2:** Run `cargo test decode`. Expected: FAIL.
- [ ] **Step 3:** Implement: a packet loop. Recoverable `DecodeError` packets are skipped, matching symphonia's guidance; IO EOF ends the loop. Allocate `Vec<f32>` with capacity from `total_frames` when known, and hand it over via `into_boxed_slice` + `Box::into_raw`.
- [ ] **Step 4:** Run `cargo test`. Expected: PASS. Commit `feat(native): decode to interleaved f32 PCM`.

### Task 6: Streaming waveform

**Files:**
- Create: `native/src/waveform.rs`
- Modify: `native/src/ffi.rs`

**Interfaces:**
- Produces (C ABI): `#[repr(u32)] enum FrustbiteWaveformMode { Peak=0, Rms=1 }` and `FrustbiteErrorCode frustbite_waveform(const FrustbiteAudio*, uint32_t buckets, uint32_t mode, bool per_channel, float** out, size_t* out_len)`. `out_len = buckets × (per_channel ? channels : 1)`, laid out channel-major (all buckets of ch0, then ch1, …).
- Values are absolute full-scale amplitude in [0, 1], not auto-normalized. `buckets` must be 1..=100_000, else `InvalidParameter`.

Algorithm (one pass, bounded memory). Decode packet by packet into a fine summary with `BLOCK = 256` frames per block: per block and per channel, keep `max |x|` for Peak, or `sum x²` + count for Rms. Merged mode takes the max/mean across channels. The summary is ~620k floats for 1 h at 44.1 kHz. At the end, map the blocks onto `buckets`: bucket `i` covers blocks `[floor(i·B/buckets), max(floor((i+1)·B/buckets), floor(i·B/buckets)+1))`, clamped to `B`. When `buckets > B`, neighbouring buckets repeat the same block value, so there is no NaN and no zero gap.

- [ ] **Step 1: Write the failing tests:**
  - `waveform_wav_peak_is_half`: buckets 100, Peak, merged → every value in [0.49, 0.51].
  - `waveform_rms_of_sine`: Rms → ≈ 0.5/√2 ± 0.01.
  - `waveform_per_channel_len`: per_channel → len 200.
  - `waveform_silence_is_zero`.
  - `waveform_more_buckets_than_frames`: click.wav with buckets 1000 → len 1000, all finite.
  - `waveform_covers_file_without_duration`: tone.webm with buckets 100 → the last bucket > 0.4.
  - `waveform_zero_buckets_invalid`: `InvalidParameter`.
- [ ] **Step 2:** Run `cargo test waveform`. Expected: FAIL.
- [ ] **Step 3:** Implement per the algorithm above.
- [ ] **Step 4:** Run `cargo test`. Expected: PASS. Commit `feat(native): streaming waveform summary`.

### Task 7: Tags and cover

**Files:**
- Create: `native/src/tags.rs`
- Modify: `native/src/ffi.rs`, `native/Cargo.toml` (add `lofty`, `serde`, `serde_json`)

**Interfaces:**
- Produces (C ABI): `FrustbiteErrorCode frustbite_get_tags_json(const FrustbiteAudio*, uint8_t** out, size_t* out_len)` returns UTF-8 JSON with the keys `title, artist, album, albumArtist, genre, comment` (string|null) and `year, track, trackTotal, disc, discTotal` (int|null). Also `FrustbiteErrorCode frustbite_get_cover(const FrustbiteAudio*, uint8_t** out, size_t* out_len, uint8_t** out_mime, size_t* out_mime_len)`; when there is no cover, both lengths are 0 with `Success`. `void frustbite_free_bytes(uint8_t*, size_t)`.
- Tag precedence: lofty's primary tag, falling back to the first other tag that has the field. ID3v1 Latin-1 bytes are decoded as Latin-1 (lofty's behaviour). We do not guess at CP1251.
- File sources are read by lofty from the path. Memory sources use a `Cursor`.

- [ ] **Step 1: Write the failing tests:**
  - `tags_mp3_full`: all fixture values, including year 2026 and track 1/1.
  - `tags_each_tagged_fixture`: title == "frustbite tone" for mp3/m4a/flac/ogg/opus.
  - `tags_missing_returns_empty`: notags.wav gives all fields null.
  - `cover_png`: tone.mp3 has mime "image/png" and data that starts with the PNG magic.
  - `cover_absent`: notags.wav gives lengths 0.
  - `tags_latin1_id3v1_title`: returns `Ok` with a non-empty title string, no error.
- [ ] **Step 2:** Run `cargo test tags`. Expected: FAIL.
- [ ] **Step 3:** Implement. Unreadable tags yield empty tags, not an error. Only a missing or unreadable file is an `IoError`.
- [ ] **Step 4:** Run `cargo test`, `cargo build --target wasm32-unknown-unknown --release`. Expected: PASS. Commit `feat(native): read tags and cover art`.

### Task 8: Dart public API on the native backend

**Files:**
- Create: `lib/src/frustbite_base.dart`, `audio_info.dart`, `audio_tags.dart`, `audio_pcm.dart`, `waveform.dart`, `enums.dart`, `frustbite_exception.dart`, `backend.dart`, `backend_native.dart`
- Modify: `lib/frustbite.dart`, regenerated bindings, `test/frustbite_test.dart`
- Create: `test/frustbite_file_test.dart`

**Interfaces:**
- Produces (Dart, public):
  ```dart
  final class Frustbite {
    static int get abiVersion;
    static Future<void> initialize({Uri? wasmUri, Uint8List? wasmBytes}); // native: no-op
    factory Frustbite.fromMemory(Uint8List bytes, {AudioContainer? format});
    factory Frustbite.fromFile(String path, {AudioContainer? format});
    AudioInfo get info;            // cached
    AudioTags get tags;            // cached
    AudioCover? get cover;         // cached
    Waveform waveform({int buckets = 100, WaveformMode mode = WaveformMode.peak, bool perChannel = false});
    AudioPcm decode();
    bool get isDisposed;
    void dispose();
  }
  enum AudioContainer { mp3, mp4, flac, ogg, wav, mkv, adts }
  enum AudioCodec { mp3, aac, alac, flac, vorbis, opus, pcm }
  enum WaveformMode { peak, rms }
  final class AudioInfo { AudioContainer container; AudioCodec codec; int sampleRate; int channels; int? bitsPerSample; int? bitrate; int totalFrames; Duration duration; }
  final class AudioTags { String? title, artist, album, albumArtist, genre, comment; int? year, track, trackTotal, disc, discTotal; static const empty; }
  final class AudioCover { Uint8List data; String mimeType; }
  final class AudioPcm { Float32List samples; int sampleRate; int channels; int get frames; Duration get duration; }
  final class Waveform { Float32List data; int buckets; int channels; Float32List channel(int i); Waveform normalized(); }
  sealed class FrustbiteException implements Exception { FrustbiteErrorCode code; String message; }
  final class UnsupportedFormatException, DecodingException, FrustbiteIoException, InvalidParameterException, InvalidPathException extends FrustbiteException
  ```
- `Waveform.normalized()` returns a copy scaled so that max == 1 (an all-zero waveform is returned unchanged).
- The native backend owns `FrustbiteAudio*` with a `NativeFinalizer(frustbite_free)` (externalSize = source byte length). The ABI is checked once, lazily, before the first open.
- Every out-buffer is copied into Dart typed data and freed natively immediately. Do not use `asTypedList` with a finalizer, because a single release path keeps the web backend symmetric.

- [ ] **Step 1: Write the failing tests** in `frustbite_test.dart` (memory) and `frustbite_file_test.dart` (fromFile):
  - `info of tone.wav`: the same values as Task 4.
  - `tags of tone.mp3`: title "frustbite tone", year 2026.
  - `cover of tone.mp3 is png`.
  - `waveform defaults to 100 merged peak buckets in [0.49, 0.51] for tone.wav`.
  - `decode tone.flac gives 132300 frames, 2 channels, 44100 Hz`.
  - `HE-AAC throws UnsupportedFormatException`.
  - `corrupt bytes throw UnsupportedFormatException or DecodingException`.
  - `missing file throws InvalidPathException`.
  - `waveform(buckets: 0) throws InvalidParameterException`.
  - `use after dispose throws StateError`.
  - `dispose twice is a no-op`.
- [ ] **Step 2:** Run `dart test`. Expected: FAIL.
- [ ] **Step 3:** Implement. `backend.dart` uses `export 'backend_native.dart' if (dart.library.js_interop) 'web/backend_web.dart';`, with the web backend stubbed so that it throws `UnimplementedError` until Task 10. `checkError(int code)` maps codes to exceptions.
- [ ] **Step 4:** Run `dart test && dart analyze --fatal-infos`. Expected: PASS. Commit `feat: public Dart API for info, tags, cover, waveform and decode`.

### Task 9: Async terminals

**Files:**
- Modify: `lib/src/frustbite_base.dart`, `lib/src/backend_native.dart`
- Create: `test/frustbite_async_test.dart`

**Interfaces:**
- Produces: `Future<Waveform> waveformAsync({…same params})` and `Future<AudioPcm> decodeAsync()`.
- Mechanism (decided): on native, `Isolate.run` captures the raw handle address (`int`), rebuilds the `Pointer`, calls the same `@Native` function, and returns Dart typed data. While a call is in flight, `Frustbite` holds a busy counter. `dispose()` then throws `StateError('Cannot dispose while an async operation is running')`, and the object stays strongly referenced until the future completes, so the finalizer cannot run. On web, the async methods run the sync call inside `Future(() => …)`.

- [ ] **Step 1: Write the failing tests:**
  - `waveformAsync equals waveform`.
  - `decodeAsync equals decode`.
  - `two concurrent async calls on one object both succeed`.
  - `dispose during waveformAsync throws StateError and does not crash`.
  - `async on disposed object throws StateError`.
- [ ] **Step 2:** Run `dart test test/frustbite_async_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `dart test`. Expected: PASS. Commit `feat: async waveform and decode`.

### Task 10: WebAssembly backend

**Files:**
- Create: `lib/src/web/wasm_runtime.dart`, `lib/src/web/backend_web.dart`, `tool/build_wasm.dart`, `test/frustbite_wasm_test.dart`
- Modify: `native/src/ffi.rs` (`#[cfg(not(target_arch="wasm32"))]` on `frustbite_open_file`), `.gitignore` (`test/frustbite.wasm`)

**Interfaces:**
- Consumes: the C ABI from Tasks 1, 4–7, plus `frustbite_alloc` and `frustbite_dealloc`.
- Produces: `WasmRuntime.load({Uri? wasmUri, Uint8List? wasmBytes})`. The default URI is `Uri.base.resolve('frustbite.wasm')`. It checks the ABI right after instantiating and throws `StateError` on mismatch. `Frustbite.initialize` must be called before any use on web; otherwise `StateError('Call Frustbite.initialize() before using frustbite on the web')`. `fromFile` throws `UnsupportedError`.

- [ ] **Step 1: Write the failing test** `frustbite_wasm_test.dart` (`@TestOn('browser')`). It loads `frustbite.wasm` from the test directory and loads fixture bytes via `fetch` of the test asset path. It runs the same info/tags/cover/waveform/decode expectations as Task 8 for tone.mp3, tone.opus and tone.webm, plus `fromFile throws UnsupportedError`.
- [ ] **Step 2:** Run `dart tool/build_wasm.dart test/frustbite.wasm && dart test -p chrome test/frustbite_wasm_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement the runtime (JS interop over the exports: alloc an input buffer, call, read the out-params from wasm memory, free) and the web backend.
- [ ] **Step 4:** Run `dart test -p chrome test/frustbite_wasm_test.dart test/frustbite_test.dart` and the same with `--compiler dart2wasm`. Expected: PASS on both. Commit `feat: WebAssembly backend`.

### Task 11: Prebuilt download path in the hook

**Files:**
- Create: `lib/src/hook/targets.dart`, `version.dart`, `hashes.dart`, `download_asset.dart`, `get_android_compiler_config.dart`, `target_versions.dart`, `tool/generate_asset_hashes.dart`, `tool/build.dart`, `test/hook_test.dart`
- Modify: `hook/build.dart`

**Interfaces:**
- Produces: `const version = 'frustbite-assets-v0.0.1';`, `Uri downloadUri(String fileName)` → `https://github.com/sb-dor/frustbite/releases/download/$version/$fileName`, the same 12 `supportedTargets` and target names as pixer (`android_armv7` … `windows_x86_64`), file names `frustbite_<target>.<dylib ext>`, `const assetHashes = <String, String>{…}` (sha256 per file name), and `Future<void> verifyAssetHash(File, …)`, which throws on mismatch and deletes the file.
- Hook logic: no code config (web) → return. `formats` user define set, or `local_build: true` → `runLocalBuild`. Otherwise download + verify + add `CodeAsset(linkMode: DynamicLoadingBundled())`.

- [ ] **Step 1: Write the failing tests** in `hook_test.dart`:
  - `readFormats accepts ["mp3","OPUS"] → ["mp3","opus"]`.
  - `readFormats rejects unknown "wma" with FormatException listing supported`.
  - `readFormats rejects empty list`.
  - `target names cover all 12 targets uniquely`.
  - `verifyAssetHash throws and deletes on mismatch`.
  - `downloadUri uses sb-dor/frustbite and the version tag`.
- [ ] **Step 2:** Run `dart test test/hook_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement. `assetHashes` starts empty. A download with no known hash throws `StateError('No hash for <file>; this package version has no prebuilt binaries — set hooks.user_defines.frustbite.local_build: true')`.
- [ ] **Step 4:** Run `dart test`. Expected: PASS (the workspace still uses `local_build: true`). Commit `feat(hook): download and verify prebuilt binaries`.

### Task 12: CI and release workflow

**Files:**
- Create: `.github/workflows/build_release.yaml`, `scripts/build.sh`

**Interfaces:**
- Triggers: PRs to `main` touching `native/**`, `packages/frustbite/**`, the workflow or `pubspec.yaml`; tags `frustbite-assets-v*`; `workflow_dispatch`.
- Jobs:
  - `preflight`: on tags, the tag must equal `frustbite-assets-v<pubspec version>`, must be referenced in `version.dart` and CHANGELOG `## <version>`, and must point at a commit on main.
  - `rust`: fmt, clippy `-D warnings`, clippy with `--no-default-features --features wav`, test.
  - `dart`: analyze + `dart test` with a local build on ubuntu/macos/windows.
  - `wasm`: build + chrome tests with dart2js and dart2wasm, then upload the artifact.
  - `build`: matrix over the 12 targets (Linux arm64 cross via `gcc-aarch64-linux-gnu`; Android via NDK; iOS/macOS on macos runners; Windows on windows runners).
  - `release`: on tags only, a GitHub Release with all 12 dylibs + `frustbite.wasm`.
- Pin third-party actions by commit SHA.

- [ ] **Step 1:** Write the workflow and `scripts/build.sh` (builds the host-buildable targets locally). Validate with `actionlint` (`brew install actionlint`, after the author's OK). Expected: no errors.
- [ ] **Step 2:** Commit `ci: build, test and release native assets`. CI only runs after the repo is pushed (Task 17).

### Task 13: Benchmarks

**Files:**
- Create: `packages/benchmark/pubspec.yaml`, `bin/main.dart`, `lib/frustbite_benchmark.dart`, `lib/baseline_benchmark.dart`, `tool/generate_inputs.sh`, `chart.html`, `README.md`, `.gitignore` (`inputs/`)
- Modify: root `pubspec.yaml` (add `packages/benchmark` to the workspace)

**Interfaces:**
- Inputs (generated, gitignored): `inputs/music.{mp3,ogg,flac,wav}`. 180 s, 44.1 kHz stereo, a synthetic "music-like" signal (chord tones + pink noise + beat envelope), mp3 CBR 192 kbps with tags + 500×500 JPEG cover.
- Cases. Each one measures the median of ≥ 10 runs after warm-up via `benchmark_harness`, from memory (bytes preloaded):

| key | frustbite | baseline(s) |
|---|---|---|
| `info_mp3` | `info` | — |
| `decode_mp3` | `decode()` | `audio_decode`, `glint_audio_pure` |
| `decode_vorbis` | `decode()` | `audio_decode` |
| `decode_flac` | `decode()` | — |
| `decode_wav` | `decode()` | `wav`, `audio_decode` |
| `waveform_mp3_1000` | `waveform(buckets: 1000)` | `audio_decode` decode + Dart bucket loop (same algorithm) |
| `tags_mp3` | `tags` + `cover` | `audio_metadata_reader` |

- Output: a console table, `benchmark_results.json` (`{timestamp, machine, dart, results: {key: {frustbite_us, <baseline>_us…}}}`), and `chart.html`, which renders the JSON as a grouped bar chart. The author exports `chart.png` from it.
- README: a table with "Operation | frustbite | baseline | Speedup", the date, the machine, the Dart version and the methodology. Rows where frustbite is slower stay in, unchanged (the author's decision).

- [ ] **Step 1:** Write `generate_inputs.sh`, run it, and check that the files exist.
- [ ] **Step 2:** Write a smoke test, `dart run bin/main.dart --quick` (1 iteration each). Expected: all keys print without exception.
- [ ] **Step 3:** Run the full `dart run bin/main.dart`. Fill in the README table from the JSON and render `chart.png` from `chart.html` (headless Chrome screenshot via the in-app browser).
- [ ] **Step 4:** Commit `bench: frustbite vs Dart audio packages`.

### Task 14: Memory acceptance check

**Files:**
- Create: `packages/frustbite/tool/memory_check.dart`

- [ ] **Step 1:** Write the tool. It generates (via ffmpeg, into the system temp dir) a 1-hour 44.1 kHz stereo mp3 at 64 kbps, records `ProcessInfo.currentRss`, runs `Frustbite.fromFile(path).waveform(buckets: 1000)` and `.info`, records `ProcessInfo.maxRss`, and prints the delta. It exits 1 if the delta is > 50 MB.
- [ ] **Step 2:** Run `dart run tool/memory_check.dart`. Expected: exit 0 with a printed delta below 50 MB.
- [ ] **Step 3:** Commit `test: memory check for 1-hour waveform`.

### Task 15: Showcase app

**Files:**
- Create: `packages/showcase/` via `flutter create --platforms=android,ios,macos,web --project-name showcase packages/showcase`, plus `lib/main.dart`, `assets/` (copies of tone.mp3, tone.opus, tone.m4a) and `README.md`
- `pubspec.yaml`: `frustbite: {path: ../frustbite}`, `file_picker` (latest stable; check pub.dev first), `hooks.user_defines.frustbite.local_build: true`

Behaviour: a screen with "Open file" and three bundled-sample buttons. After loading, it shows the info card (codec, container, rate, channels, duration, bitrate), the tags + cover image, and a waveform painted by `CustomPainter` from `waveformAsync(buckets: width.round())`. Errors show the exception message. On web, it calls `Frustbite.initialize()` on start and documents placing `frustbite.wasm` into `web/`.

- [ ] **Step 1:** Write the widget test `shows info and waveform for bundled tone.mp3`. It finds the text `mp3`, the text `0:03`, and a `CustomPaint` with the key `waveform`.
- [ ] **Step 2:** Run `flutter test`. Expected: FAIL, then implement, then PASS.
- [ ] **Step 3:** Manually run `flutter run -d macos` and confirm that the waveform and tags render for each sample. Do the same on an iOS simulator via the simulator tool.
- [ ] **Step 4:** Commit `feat(showcase): Flutter demo app`.

### Task 16: Docs, README, example, CHANGELOG

**Files:**
- Create: `docs/package.json` (blume 1.6.1 or latest; node ≥ 22.12), `docs/blume.config.ts` (owner `sb-dor`, repo `frustbite`, site `https://sb-dor.github.io`, base `/frustbite`), `docs/content/index.mdx`, `01-getting-started.mdx`, `02-reading-audio.mdx` (info, tags, cover, waveform, decode, async), `03-webassembly.mdx`, `04-formats-and-build.mdx` (formats, HE-AAC note, `formats` user define), `.github/workflows/docs.yaml` (build on push to main → GitHub Pages)
- Create/Modify: root `README.md` (as in pixer: one paragraph + links), `packages/frustbite/README.md` (install, quick start, formats, web, async, roadmap of stages 2–5), `CHANGELOG.md` (`## 0.0.1`), `example/frustbite_example.dart`, `.pubignore` (exclude `test/fixtures`, `tool/`, `native/include` is kept)

- [ ] **Step 1:** Write the docs. Run `cd docs && npm install && npm run docs:build && npm run docs:check`. Expected: the build succeeds and the checks pass.
- [ ] **Step 2:** Run `dart run example/frustbite_example.dart test/fixtures/tone.mp3`. Expected: it prints info, tags and a 20-char ASCII waveform.
- [ ] **Step 3:** Commit `docs: site, README, example and changelog`.

### Task 17: Publish repo and first asset release

Every step that touches GitHub needs the author's explicit OK in chat right before it.

- [ ] **Step 1:** Ask the author, then run `gh repo create sb-dor/frustbite --public --source . --remote origin` and `git push -u origin main`. Enable GitHub Pages (Actions source) after a second OK.
- [ ] **Step 2:** Wait for the PR/push CI to go green. (The app watches CI; do not poll it manually.)
- [ ] **Step 3:** Ask the author, then tag `frustbite-assets-v0.0.1` and push the tag. The release job uploads the 13 files.
- [ ] **Step 4:** Run `dart tool/generate_asset_hashes.dart` to fill `hashes.dart` from the release. Commit `chore: asset hashes for 0.0.1`.
- [ ] **Step 5:** In a scratch app outside the workspace (no `local_build`), depend on `frustbite` by path or git, run `dart test` on macOS, and confirm the binary was downloaded and verified. Expected: PASS without Rust on PATH (use `env -u CARGO_HOME PATH=…` without cargo).
- [ ] **Step 6:** Run `cd packages/frustbite && dart pub publish --dry-run`. Expected: 0 warnings. Stop here. Publishing to pub.dev is stage 5 or a separate decision by the author.
