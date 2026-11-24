# Decisions

The rulings that shaped frustbite, with their status. Stage 1 rulings (R1 to
R27) were made while building the reading stage; the distribution rulings (D-A
to D-L, plus two deviations) came with distribution v2 (version 0.0.2). The
design of distribution v2 follows [PlugFox/ws](https://github.com/PlugFox/ws)
(MIT); the code is written for frustbite.

Status: **adopted** (in force), **superseded** (replaced by a later entry),
**lifted** (the restriction no longer applies).

## Stage 1 rulings

| ID | Ruling | Status |
| --- | --- | --- |
| R1 | Rust tests read fixtures through `CARGO_MANIFEST_DIR` (`../packages/frustbite/test/fixtures/`), not a symlink. | adopted |
| R2 | The web async work (`*Async` on the web) is done in the web task: the methods only defer to a later event-loop turn. | adopted |
| R3 | `actionlint` is clean on every workflow. | adopted |
| R4 | Browser and simulator steps are run by the controller, not by a sub-agent. | adopted |
| R5 | Rust toolchain 1.100.0, pinned in `native/rust-toolchain.toml`. | adopted |
| R6 | The author creates the GitHub repository. | adopted |
| R7 | Test fixtures of about 2.3 MB in total are acceptable in the repository. | adopted |
| R8 | No Opus in MP4 in stage 1 (Opus in Ogg and WebM is supported). | adopted |
| R9 | No seeking in stage 1. | adopted |
| R10 | `panic = "unwind"`, so a panic is caught at the FFI boundary and mapped to an error code. | adopted |
| R11 | HE-AAC with implicit SBR (and ADTS HE-AAC) cannot be detected on open, and may decode as the AAC-LC core. Documented as a limitation. | adopted |
| R12 | `source_byte_length` semantics: the size of the opened source in bytes (file size, or the length of the byte buffer). | adopted |
| R13 | `symphonia` is pinned to `=0.6.1`. | adopted |
| R14 | The pin also covers `symphonia-core`: upstream `packet.rs:340` has a trim bug, so upgrades need a manual check. Dependabot ignores both. | adopted |
| R15 | Codec features are test-gated: every test that needs a codec is compiled only with its feature. | adopted |
| R16 | The ABI version stays 1 until the first release. | adopted |
| R17 | `FrustbiteErrorCode` is exported in the public API. | adopted |
| R18 | The `format:` hint is advisory: content detection wins and a wrong hint is not an error. | adopted |
| R19 | wasm traps map to `UnknownFrustbiteException`, and the instance is poisoned after a trap. | adopted |
| R20 | The wasm bridge copies bulk data with bulk typed-array copies, not per element. | adopted |
| R21 | CSP fallback: where the page forbids `unsafe-eval`, a Rust panic under dart2wasm escapes as a raw JavaScript error. Documented. | adopted |
| R22 | Linux binaries are built on `ubuntu-22.04`, so they need glibc 2.35. | superseded by D-G (zigbuild, glibc 2.17) |
| R23 | Benchmark fairness: same inputs, same machine, native and pure-Dart packages in one table including the rows where frustbite is slower. | adopted |
| R24 | The showcase ships a demo sample. | adopted |
| R25 | Source builds work only through a git dependency, because the Rust crate is not in the pub.dev package. | lifted by D-D (the package carries `rust/`) |
| R26 | A final review runs before the release. | adopted |
| R27 | Android minimum is API 30. | adopted (lowering it is on the [roadmap](ROADMAP.md)) |

## Distribution v2 rulings

### D-A. One library file name on every target

The name comes from `OS.dylibFileName('frustbite')`: `libfrustbite.so`,
`libfrustbite.dylib` or `frustbite.dll`. The target lives only in the directory
`prebuilt/<os>-<arch>[-sim]/`. This fixes the Flutter warning about different
framework names per architecture. Status: adopted.

### D-B. Bundle the prebuilt libraries in the pub archive, do not download them

`prebuilt/` is gitignored in the repository and present in the published
archive. `prebuilt/checksums.json` maps `<target>/<file>` to its SHA-256 and the
hook verifies it. The GitHub download path (`download_asset.dart`,
`hashes.dart`, `version.dart`, the `generate_asset_hashes` tool and the
`frustbite-assets-v` tags of 0.0.1) is gone. The GitHub Release stays as the
source of the bundled files and of `frustbite.wasm`. Status: adopted.

### D-C. Hook resolution order

1. `user_defines.frustbite.library: <path>`, used as is; it must exist.
2. `source` is `auto` (default), `prebuilt`, `build` or `none`. `auto` takes the
   bundled library, else cargo if the crate is present and cargo works, else a
   `StateError` that explains the options. `none` adds no asset.
3. `formats: [...]` implies `source: build`: the prebuilt has every codec.
4. `local_build: true` is an alias for `source: build` (the workspace uses it).
5. A per-OS map such as `{default: prebuilt, linux: build}` is accepted; unknown
   keys and values are errors. As in sqlite3 3.6+ and ws.

Status: adopted.

### D-D. Crate location for the cargo path

First `<packageRoot>/rust/` (the published package), then
`<packageRoot>/../../native/` (repository checkout or git dependency). This
lifts R25: source builds work from pub.dev too, given cargo. Status: adopted.

### D-E. Cargo build in the hook

The hook runs `cargo build --release --locked` directly (not
`native_toolchain_rust`) so it controls the environment, the `--config` file and
the target directory. The target directory is
`outputDirectoryShared/cargo/<key>/`, where the key includes the Android NDK API
or the Apple deployment target, because cargo does not fingerprint those. The
built file is copied to `outputDirectory/<one file name>`. `output.dependencies`
lists the existing files only: Cargo.toml, Cargo.lock, build.rs, `src/*.rs`,
`checksums.json` and the prebuilt file. Cargo is found on `PATH`, then in
`$CARGO_HOME/bin`, then in `~/.cargo/bin`. Status: adopted.

### D-F. Linker flags live in `native/build.rs`

A user's `RUSTFLAGS` overrides config rustflags, so `build.rs` sets them:
Android `-Wl,-z,max-page-size=16384`; macOS and iOS `-headerpad_max_install_names`
and `-install_name @rpath/libfrustbite.dylib`; Linux `-static-libgcc`. Windows
MSVC links the C runtime statically (`+crt-static`). The Android rustflags left
`.cargo/config.toml`. Status: adopted (see the deviation below for Windows).

### D-G. Linux binaries are built with `cargo zigbuild` against glibc 2.17

`--target x86_64-unknown-linux-gnu.2.17` instead of an `ubuntu-22.04` build
(glibc 2.35). Documented minimum: glibc 2.17. Supersedes R22. Status: adopted.

### D-H. `tool/verify_native.sh <file> <target>` runs in CI after every build

It fails on: an exported symbol not prefixed `frustbite_` (plus an expected
count); Android LOAD segments not aligned to 16 KB; Linux needing glibc newer
than 2.17 or a `NEEDED` library outside an allow-list; an Apple install name
other than `@rpath/libfrustbite.dylib` or a minos below the target minimum; a
Windows import of `VCRUNTIME*` or `MSVCP*`. Status: adopted.

### D-I. Release and publish chain

A tag `frustbite-v<version>` (renamed from `frustbite-assets-v...`) builds and
verifies the 12 targets and the wasm, then creates the GitHub Release with the
12 libraries, `frustbite.wasm`, `THIRD_PARTY_LICENSES.md` and `checksums.json`.
CI also stages the package and runs `dart pub publish --dry-run` on the staged
copy, on pull requests too. Publishing stays manual, by the author.
`tool/stage_package.dart (--from-dir <dir> | --from-release <tag>) --out <dir>`
builds the staged package outside the repository (see the deviation below for
what `--from-release` checks). It fails with fewer than 12 libraries.
`tool/check_pubignore.dart` checks the staged `.pubignore` keeps `prebuilt/` and
`rust/` and drops `rust/target/`. Status: adopted.

### D-J. Version 0.0.2

The package is not on pub.dev yet. The CHANGELOG `## 0.0.2` describes the
distribution change. PR #4 (hashes for 0.0.1) is superseded by D-B. Status:
adopted.

### D-K. iOS privacy manifest

`nm -u` on the iOS libraries (`ios_arm64`, `ios_sim_arm64`, `ios_sim_x86_64`)
shows two required-reason imports, `stat` and `fstat`, both file timestamp
category (Rust `std::fs` opening a file and reading its size). None of
`lstat`, `fstatat`, `getattrlist`, `fgetattrlist`, `getattrlistbulk`,
`mach_absolute_time`, `statfs`, `fstatfs`, `statvfs` or `fstatvfs` is imported.
A pure Dart package cannot ship a `PrivacyInfo.xcprivacy`, so the README and the
getting-started page tell an app to declare
`NSPrivacyAccessedAPICategoryFileTimestamp` with `C617.1` (files in the app
container) and/or `3B52.1` (files the user picked). `0A2A.1` is for SDK wrappers
and is not recommended. Status: adopted. Re-run `nm -u` when the dependencies
change.

### D-L. Docs, roadmap and tasks

This file, `docs/ROADMAP.md`, `mise.toml`, and the README and docs pages
(distribution, offline builds, `source`/`library`/`formats`, glibc 2.17, the
privacy manifest). Status: adopted.

### Deviation: the staged `rust/cargo-config.toml`

D-F put the Windows `+crt-static` tables in `native/.cargo/config.toml`. pub
drops hidden files from the archive, so the staged package carries them as the
visible `rust/cargo-config.toml`, and the hook passes it to cargo with
`--config`. In the repository, the crate's own `.cargo/config.toml` applies.
Status: adopted.

### Deviation: `--from-release` checks its source

D-I had `--from-release <tag>` take the release libraries only. The staged
Dart and Rust sources come from the working tree, so the command also checks
that the tag exists, that `HEAD` is the tag's commit, that the tree is clean,
that the version matches `pubspec.yaml`, and that the downloaded libraries match
the release's `checksums.json`. Status: adopted.

### Deviation: the staged crate is trimmed for source builds

The repository's `native/rust-toolchain.toml` lists clippy, rustfmt and 13
targets, which a source build from pub.dev would install (hundreds of MB, and
possibly past the hook's 5-minute rustup timeout). The stager writes
`rust/rust-toolchain.toml` with the same `channel`, `profile = "minimal"` and
no components or targets, and appends an empty `[workspace]` table to
`rust/Cargo.toml` so cargo does not refuse a pub cache under someone's
workspace. The hook then runs `rustup toolchain install --no-self-update` and
`rustup target add <triple> --toolchain <channel>`, both best effort with the
same timeout; cargo reports real problems. Status: adopted.

### Deviation: release binaries carry no build machine paths

CI builds with `tool/build.dart --release-paths`, which remaps the home,
rustup, cargo and checkout directories with `--remap-path-prefix` through
`CARGO_ENCODED_RUSTFLAGS` (repeating the Windows `+crt-static` flag, since the
variable replaces the config's rustflags). Only CI-built libraries are staged
for publishing. The local `aarch64-linux-gnu-gcc` linker table left
`native/.cargo/config.toml`; `tool/build.dart` sets the linker through the
environment for a plain arm64 Linux cross build. Status: adopted.
