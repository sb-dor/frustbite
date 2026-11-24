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
from source (`native/`) instead of looking for a bundled `prebuilt/` library,
which only the published package has.

[mise](https://mise.jdx.dev) is optional: `mise.toml` wraps the commands below
as tasks (`mise run fmt`, `fmt:check`, `analyze`, `test`, `check`,
`build:native`, `verify:native`, `stage`, `publish:check`). Plain shell works
the same.

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

# a built native library, from the repo root (CI does this for every target)
tool/verify_native.sh <file> <target>   # e.g. build/native/macos_arm64/libfrustbite.dylib macos_arm64

# docs, from docs/
npm ci && npm run docs:build && npm run docs:check
```

CI runs the same checks on every pull request.

## Local cross builds

`scripts/build.sh [output-dir] [target...]` builds the libraries this host can
build, through `packages/frustbite/tool/build.dart`. CI cross-builds the Linux
targets with `cargo zigbuild` (glibc 2.17; `--zigbuild` or
`FRUSTBITE_ZIGBUILD=1`, needs `ziglang` and `cargo-zigbuild`). Without it, an
arm64 Linux library on an x86_64 Linux host needs `aarch64-linux-gnu-gcc`
(`apt install gcc-aarch64-linux-gnu`); `tool/build.dart` points cargo at it
through `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER`. The crate's
`.cargo/config.toml` holds no linker setting, so a git dependency or plain
`cargo build` in `native/` uses the host's linker.

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
Publishing to pub.dev stays manual, by the author. Check out the tag first:
`stage_package.dart --from-release` refuses unless the tag exists, `HEAD` is
the tag's commit, `packages/frustbite` and `native` are clean, and the tag
matches the `pubspec.yaml` version. It downloads the 12 libraries with `gh`
(they must match the release's `checksums.json`) and stages the package
outside the repository:

```sh
git fetch --tags && git checkout frustbite-vX.Y.Z
cd packages/frustbite
dart tool/stage_package.dart --from-release frustbite-vX.Y.Z --out ../../../frustbite-stage
dart tool/check_pubignore.dart ../../../frustbite-stage
cd ../../../frustbite-stage && dart pub publish
```

Only CI-built artifacts are staged for publishing. The release workflow builds
with `tool/build.dart --release-paths`, which remaps the home, rustup, cargo
and checkout directories (`--remap-path-prefix`), so the binaries hold no
build machine paths; a library built on your own machine does not, and must
not go into a published package.

The same staging and dry run run on every pull request and manual run of the
workflow, from that run's own build artifacts. The published package bundles
the libraries under `prebuilt/` (verified by the hook against
`prebuilt/checksums.json`) and the crate under `rust/`; nothing is downloaded
at build time.

Design decisions and their status are in [docs/DECISIONS.md](docs/DECISIONS.md),
planned work in [docs/ROADMAP.md](docs/ROADMAP.md).
