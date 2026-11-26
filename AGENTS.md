# Frustbite

A pure-Dart audio library backed by a Rust crate through FFI and Dart build hooks. Pure Dart only: no Flutter plugin structure, no platform channels, no pigeon.

## Repo map

- `native/`: Rust crate (`staticlib` + `cdylib`).
  - `src/lib.rs`: crate entry; `src/ffi.rs`: C ABI; `src/error.rs`: `FrustbiteErrorCode`; `src/wasm_alloc.rs`: wasm32-only alloc/dealloc.
  - Editing: `src/edit.rs` (JSON operation list `Op`, `render`, rubato resampling), `src/wav.rs` (WAV writer, `FrustbiteWavFormat`), `src/silence.rs` (streaming `detect_silence`).
  - `include/frustbite.h`: generated C header.
  - `cbindgen.toml`, `rust-toolchain.toml`, `.cargo/config.toml`.
- `packages/frustbite/`: the Dart package.
  - `hook/build.dart`: build hook. `library: <path>` first; then `source: auto|prebuilt|build|none` (default `auto`: the bundled `prebuilt/<os>-<arch>[-sim]/<one file name>` verified against `prebuilt/checksums.json`, else `cargo build`, else a StateError). `formats` and `local_build: true` mean `source: build`.
  - `lib/src/hook/`: `resolve.dart` (pure hook decisions: source parsing, `prebuilt/` directory names, checksum check, crate lookup `rust/` then `../../native/`), `local_build.dart` (direct `cargo build --release --locked` in the crate dir), `targets.dart` (12 targets, Rust triples), `target_versions.dart` and `get_android_compiler_config.dart` (NDK/OS minimums, as pixer).
  - `tool/build.dart [--zigbuild] [--release-paths] <dir> <target>...|all`: builds release libraries (`--release-paths`, used by CI, remaps home/cargo/rustup/checkout paths out of the binaries; only CI-built libraries are staged for publishing) into `<dir>/<target>/<one file name>` (`libfrustbite.so`/`.dylib`, `frustbite.dll`); Linux uses `cargo zigbuild` (glibc 2.17) with `--zigbuild` or `FRUSTBITE_ZIGBUILD=1`. `tool/verify_native.sh <file> <target>` (repo root) checks exports, 16 KB alignment, glibc, install name, min OS and CRT; CI runs it on every build.
  - `tool/stage_package.dart (--from-dir <dir> | --from-release <tag>) --out <dir>`: stages the package outside the repo for publishing: the git-tracked files, `native/` as `rust/` (Cargo.toml (plus an empty `[workspace]` table), Cargo.lock, build.rs, a trimmed `rust-toolchain.toml` (channel + `profile = "minimal"`; the hook adds the one target), `src/`, and `cargo-config.toml`, the Windows `+crt-static` tables of `.cargo/config.toml`: pub drops hidden files, so the hook passes it with `--config`), the libraries as `prebuilt/<os>-<arch>[-sim]/<one file name>` and `prebuilt/checksums.json`. Fails with fewer than 12 libraries (`--allow-partial` is for local tests). `tool/check_pubignore.dart <staged dir>` checks the staged `.pubignore` keeps `prebuilt/` and `rust/` and drops `rust/target/`.
  - `lib/src/bindings/bindings.dart`: generated `@Native` bindings; `lib/src/enums.dart`: generated shared enums.
  - `lib/src/abi.dart`: ABI constant and check; `tool/generate_bindings.dart`: generator.
  - `lib/src/audio_edit.dart` (`part of` `frustbite_base.dart`): the lazy `AudioEdit` builder; it encodes the operations as JSON for `frustbite_render`/`frustbite_render_wav`.
  - `lib/src/backend.dart`: picks `backend_native.dart` (FFI) or `web/backend_web.dart` + `web/wasm_runtime.dart` (`dart:js_interop` over `frustbite.wasm`); both expose the same `BackendAudio` surface.
  - `tool/build_wasm.dart`: builds `frustbite.wasm` (release, `wasm32-unknown-unknown`) and copies it to the given path.
  - `test/`: Dart tests; `test/fixtures/`: audio fixtures.
- Root `pubspec.yaml`: pub workspace; `hooks.user_defines.frustbite.local_build: true` builds from source.
- `docs/DECISIONS.md`: rulings R1-R27 (stage 1) and D-A..D-L (distribution v2) with status; `docs/ROADMAP.md`: stages 2-5 and open items. Add a decision there when you make one.
- `mise.toml`: optional task runner (`fmt`, `fmt:check`, `analyze`, `test`, `check`, `build:native`, `verify:native`, `stage`, `publish:check`) wrapping the commands below.

## Commands

Run `source "$HOME/.cargo/env"` first in a fresh shell.

```bash
# Rust (from native/)
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check

# Regenerate THIRD_PARTY_LICENSES.md (root + packages/frustbite copy) after any Cargo.lock change;
# CI runs it with --check (from the repo root)
python3 -I native/tool/third_party_licenses.py

# Regenerate header + bindings (from packages/frustbite/); needs `cargo install cbindgen`
dart tool/generate_bindings.dart

# Dart (from packages/frustbite/)
dart analyze --fatal-infos
dart test

# Memory acceptance: 1-hour mp3 waveform stays within 50 MB RSS (needs ffmpeg; ~1 min)
dart run tool/memory_check.dart

# wasm: check the crate still builds for the web target (from native/)
cargo clippy --target wasm32-unknown-unknown -- -D warnings

# wasm browser tests (from packages/frustbite/; needs Chrome). Only the wasm test file runs in the
# browser: the other test files use dart:io / dart:ffi.
dart tool/build_wasm.dart test/frustbite.wasm
dart test -p chrome test/frustbite_wasm_test.dart
dart test -p chrome --compiler dart2wasm test/frustbite_wasm_test.dart

# Benchmarks (from packages/benchmark/; needs ffmpeg with libmp3lame for the inputs)
./tool/generate_inputs.sh
dart run bin/main.dart           # full run: writes benchmark_results.json, updates chart.html
dart run bin/main.dart --quick   # smoke test, writes nothing

# Showcase (from packages/showcase/; Flutter app, needs a Rust toolchain)
flutter run -d macos
flutter test
# web: dart tool/build_wasm.dart ../showcase/web/frustbite.wasm (from packages/frustbite/), then
flutter run -d chrome

# Docs site (from docs/; Blume, Node >= 22.12)
npm install
npm run docs:dev
npm run docs:build && npm run docs:check

# Native libraries for this host (output dir may be relative)
scripts/build.sh [output-dir] [target...]

# Stage the package and dry-run the publish (from packages/frustbite/; needs the 12 libraries,
# e.g. from `dart tool/build.dart libs all`; the stage dir must be outside the repo)
dart tool/stage_package.dart --from-dir libs --out ../../../frustbite-stage
dart tool/check_pubignore.dart ../../../frustbite-stage
(cd ../../../frustbite-stage && dart pub publish --dry-run)
```

## Rules

- Never edit generated files: `packages/frustbite/lib/src/bindings/bindings.dart`, `packages/frustbite/lib/src/enums.dart`, `native/include/frustbite.h`. Change the Rust source or `tool/generate_bindings.dart` and regenerate.
- ABI bump: `FRUSTBITE_ABI_VERSION` in `native/src/ffi.rs` and `frustbiteAbiVersion` in `packages/frustbite/lib/src/abi.dart` must change together. Bump for any incompatible signature, layout or ID change.
- Error code 7 is reserved for `EncodingError` (stage 3).
- Pure Rust dependencies only; each must build for `wasm32-unknown-unknown`. Licenses: MIT, Apache-2.0, BSD, Zlib or MPL-2.0.
- Codec Cargo features (`mp3`, `aac`, `alac`, `flac`, `vorbis`, `opus`, `wav`) stay in sync with `supportedFormats` in `lib/src/hook/local_build.dart`.
- Rust tests read fixtures via `concat!(env!("CARGO_MANIFEST_DIR"), "/../packages/frustbite/test/fixtures/")`, not a symlink.
