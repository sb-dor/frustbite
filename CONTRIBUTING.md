# Contributing

Thanks for helping with frustbite. [AGENTS.md](AGENTS.md) has the repository
layout and the full command list; this page is the short version.

## Setup

- Rust via [rustup](https://rustup.rs). The toolchain is pinned in
  `native/rust-toolchain.toml` and installs itself (with the wasm, Android, iOS
  and desktop targets) on first use in `native/`.
- `cargo install cbindgen`, needed to regenerate the C header and bindings.
- Dart (stable), or Flutter for `packages/showcase`.
- Node 22.12 or newer, only for the docs site in `docs/`.
- Chrome, only for the wasm tests.

```bash
source "$HOME/.cargo/env"
dart pub get   # from the repo root; a pub workspace
```

The workspace sets `local_build: true`, so the build hook compiles the crate
from source instead of downloading a release.

## Checks

```bash
# from native/
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test

# from the repo root, after any Cargo.lock change
python3 -I native/tool/third_party_licenses.py

# from packages/frustbite/
dart analyze --fatal-infos
dart test

# web code: build the wasm, then run in Chrome
dart tool/build_wasm.dart test/frustbite.wasm
dart test -p chrome test/frustbite_wasm_test.dart
dart test -p chrome --compiler dart2wasm test/frustbite_wasm_test.dart

# docs, from docs/
npm ci && npm run docs:build && npm run docs:check
```

CI runs the same checks on every pull request.

## Rules

- **Generated files are never edited by hand**: `bindings.dart`, `enums.dart`,
  and `native/include/frustbite.h`. Change the Rust source or
  `tool/generate_bindings.dart` and regenerate with
  `dart tool/generate_bindings.dart` (from `packages/frustbite/`).
- **ABI bump**: `FRUSTBITE_ABI_VERSION` in `native/src/ffi.rs` and
  `frustbiteAbiVersion` in `packages/frustbite/lib/src/abi.dart` change
  together, for any incompatible signature, layout or ID change.
- **Pure Rust only**: every dependency must be pure Rust and build for
  `wasm32-unknown-unknown`. Allowed licenses: MIT, Apache-2.0, BSD, Zlib or
  MPL-2.0. No FFmpeg or C codecs.
- **Codec features stay in sync**: the Cargo features (`mp3`, `aac`, `alac`,
  `flac`, `vorbis`, `opus`, `wav`) must match `supportedFormats` in
  `packages/frustbite/lib/src/hook/local_build.dart`.
- Update `packages/frustbite/CHANGELOG.md` for user-visible changes.

## Releases

Maintainers release by pushing a tag `frustbite-vX.Y.Z` on `main`. The
tag must match the `pubspec.yaml` version and a
`## X.Y.Z` section in the CHANGELOG. The `build_release.yaml` workflow then
builds and verifies the 12 native libraries and `frustbite.wasm`, stages the
package (`packages/frustbite/tool/stage_package.dart`) and runs
`dart pub publish --dry-run` on it, then creates the GitHub Release with the
libraries, `frustbite.wasm`, `THIRD_PARTY_LICENSES.md` and `checksums.json`.
Publishing to pub.dev stays manual, from the released assets:

```sh
cd packages/frustbite
dart tool/stage_package.dart --from-release frustbite-vX.Y.Z --out ../../../frustbite-stage
dart tool/check_pubignore.dart ../../../frustbite-stage
cd ../../../frustbite-stage && dart pub publish
```

The same staging and dry run run on every pull request and manual run of the
workflow, from that run's own build artifacts.
