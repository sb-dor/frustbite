## What and why

<!-- Describe the change and link the issue it closes. -->

## Checklist

- [ ] Rust (from `native/`): `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` and `cargo test` pass
- [ ] Dart (from `packages/frustbite/`): `dart analyze --fatal-infos` and `dart test` pass
- [ ] Web code changed: the wasm tests pass (`dart tool/build_wasm.dart test/frustbite.wasm`, then `dart test -p chrome` with dart2js and `--compiler dart2wasm`)
- [ ] Generated files were regenerated, not hand-edited (`bindings.dart`, `enums.dart`, `hashes.dart`, `frustbite.h`, `THIRD_PARTY_LICENSES.md`)
- [ ] ABI: if a signature, layout or ID changed, `FRUSTBITE_ABI_VERSION` (`native/src/ffi.rs`) and `frustbiteAbiVersion` (`lib/src/abi.dart`) were bumped together
- [ ] `packages/frustbite/CHANGELOG.md` is updated
