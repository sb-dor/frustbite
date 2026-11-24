# Frustbite

A pure-Dart audio library backed by a Rust crate through FFI and Dart build hooks. Pure Dart only: no Flutter plugin structure, no platform channels, no pigeon.

## Repo map

- `native/`: Rust crate (`staticlib` + `cdylib`).
  - `src/lib.rs`: crate entry; `src/ffi.rs`: C ABI; `src/error.rs`: `FrustbiteErrorCode`; `src/wasm_alloc.rs`: wasm32-only alloc/dealloc.
  - `include/frustbite.h`: generated C header.
  - `cbindgen.toml`, `rust-toolchain.toml`, `.cargo/config.toml`.
- `packages/frustbite/`: the Dart package.
  - `hook/build.dart`: build hook; `lib/src/hook/local_build.dart`: source build via `native_toolchain_rust`.
  - `lib/src/bindings/bindings.dart`: generated `@Native` bindings; `lib/src/enums.dart`: generated shared enums.
  - `lib/src/abi.dart`: ABI constant and check; `tool/generate_bindings.dart`: generator.
  - `test/`: Dart tests; `test/fixtures/`: audio fixtures.
- Root `pubspec.yaml`: pub workspace; `hooks.user_defines.frustbite.local_build: true` builds from source.

## Commands

Run `source "$HOME/.cargo/env"` first in a fresh shell.

```bash
# Rust (from native/)
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check

# Regenerate header + bindings (from packages/frustbite/); needs `cargo install cbindgen`
dart tool/generate_bindings.dart

# Dart (from packages/frustbite/)
dart analyze --fatal-infos
dart test

# wasm: check the crate still builds for the web target (from native/)
cargo clippy --target wasm32-unknown-unknown -- -D warnings

# Benchmarks: added in a later stage
```

## Rules

- Never edit generated files: `packages/frustbite/lib/src/bindings/bindings.dart`, `packages/frustbite/lib/src/enums.dart`, `native/include/frustbite.h`. Change the Rust source or `tool/generate_bindings.dart` and regenerate.
- ABI bump: `frustbite_abi_version` in `native/src/ffi.rs` and `frustbiteAbiVersion` in `packages/frustbite/lib/src/abi.dart` must change together. Bump for any incompatible signature, layout or ID change.
- Error code 7 is reserved for `EncodingError` (stage 3).
- Pure Rust dependencies only; each must build for `wasm32-unknown-unknown`. Licenses: MIT, Apache-2.0, BSD, Zlib or MPL-2.0.
- Codec Cargo features (`mp3`, `aac`, `alac`, `flac`, `vorbis`, `opus`, `wav`) stay in sync with `supportedFormats` in `lib/src/hook/local_build.dart`.
- Rust tests read fixtures via `concat!(env!("CARGO_MANIFEST_DIR"), "/../packages/frustbite/test/fixtures/")`, not a symlink.
