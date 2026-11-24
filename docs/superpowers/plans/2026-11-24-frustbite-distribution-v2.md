# frustbite distribution v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship frustbite's native libraries inside the pub package, built portably and verified, instead of downloading them from GitHub at build time. The approach follows PlugFox/ws.

**Architecture:**
- The published package contains these files:
  - `prebuilt/<target>/<one file name>`;
  - `prebuilt/checksums.json`;
  - `rust/`, a copy of the crate.
- The hook resolves the library in this order:
  1. `library:` override;
  2. bundled prebuilt, verified by sha256;
  3. `cargo build` of `rust/` (or `../../native` in a repo checkout);
  4. a clear error.
- The published package is staged outside the repo, as in ws D25.
- Linker flags live in `build.rs`.
- Every CI-built binary is checked by `tool/verify_native.sh`.

**Tech Stack:** Dart hooks/code_assets, Rust build.rs, cargo-zigbuild (Linux, glibc 2.17), GitHub Actions.

**Spec:**
- `docs/superpowers/specs/2026-11-24-frustbite-design.md`, plus this plan's Decisions.
- Reference: https://github.com/PlugFox/ws: `native/hook/build.dart`, `native/rust/build.rs`, `docs/DECISIONS.md` D9/D10/D25/D30/D31/D40, `docs/NATIVE_DISTRIBUTION.md`, `tool/verify_native.sh`, `tool/stage_native.sh`.
- Read those for the pattern. Write our own code; do not copy verbatim. Credit PlugFox/ws (MIT) where a file is adapted.

## Decisions (author approved "all including bundling", 2026-11-24)

- **D-A. One library file name on every target.** It comes from `OS.dylibFileName('frustbite')`: `libfrustbite.so`, `libfrustbite.dylib` or `frustbite.dll`. The per-target name lives only in the directory: `prebuilt/<os>-<arch>[-sim]/`. This fixes the Flutter warning "different framework names for different architectures", which a macOS release build shows today.
- **D-B. Bundle the prebuilt libraries in the pub archive. Do not download them.**
  - `prebuilt/` is gitignored in the repo and present in the published archive.
  - `prebuilt/checksums.json` maps `<target>/<file>` to its sha256, and the hook verifies it.
  - The GitHub download path, `lib/src/hook/download_asset.dart`, `hashes.dart` and `version.dart`, is removed.
  - The GitHub Release stays as the source of the bundled files and of `frustbite.wasm`.
- **D-C. Hook resolution order:**
  1. `user_defines.frustbite.library: <path>`, used as is. It must exist.
  2. `source` is one of `auto` (default), `prebuilt`, `build`, `none`:
     - `none`: add no asset. The app then gets the existing "missing native library" error at the first call.
     - `prebuilt`: bundled only. Error if it is missing.
     - `build`: cargo only.
     - `auto`: prebuilt if present, else cargo if the crate is present and cargo is on PATH, else a `StateError` that explains the options.
  3. `formats: [...]` implies `source: build`. A custom codec set can't come from the prebuilt.
  4. `local_build: true` stays as an alias for `source: build`. The workspace uses it.
  5. A per-OS map, e.g. `source: {default: prebuilt, linux: build}`, is accepted, as in sqlite3 3.6+ and ws.
- **D-D. Crate location for the cargo path.** First `<packageRoot>/rust/` (the published package), then `<packageRoot>/../../native/` (repo checkout or git dependency). This lifts ruling R25: source builds now work from pub.dev too, given cargo.
- **D-E. Cargo build in the hook:**
  - Use `--release --locked`.
  - Set `--target-dir` to `input.outputDirectoryShared/cargo/<key>/`, where the key includes the Android NDK API or the Apple deployment target, because cargo does not fingerprint those.
  - Copy the built file to `outputDirectory/<one file name>`.
  - Register `output.dependencies`: Cargo.toml, Cargo.lock, build.rs, src/*.rs, checksums.json and the prebuilt file. List only existing files, as in ws D29.
  - The hook keeps using `native_toolchain_rust`'s `RustBuilder`, if it supports a custom target dir and environment. Otherwise it runs `cargo` directly, as ws does. The implementer chooses and says why.
- **D-F. Linker flags in `native/build.rs`, not in `.cargo/config.toml`** (a user's `RUSTFLAGS` overrides config rustflags):
  - android: `-Wl,-z,max-page-size=16384`;
  - macos and ios: `-Wl,-headerpad_max_install_names` and `-Wl,-install_name,@rpath/libfrustbite.dylib`;
  - linux: `-static-libgcc`.
  - Windows MSVC links the C runtime statically (`+crt-static` for `*-pc-windows-msvc` in `native/.cargo/config.toml`).
  - The Android rustflags are removed from `.cargo/config.toml`.
- **D-G. Linux binaries are built with `cargo zigbuild` against glibc 2.17** (`--target x86_64-unknown-linux-gnu.2.17`), instead of on ubuntu-22.04 (glibc 2.35). Documented minimum: glibc 2.17.
- **D-H. `tool/verify_native.sh <file> <target>` runs in CI after every build** and fails on:
  - an exported symbol not prefixed `frustbite_`, plus an expected exact count;
  - Android LOAD segments not aligned to 16 KB;
  - Linux needing glibc > 2.17, or a `NEEDED` library outside an allow-list (libc, libm, libdl, libpthread, ld-linux, librt);
  - an Apple install name other than `@rpath/libfrustbite.dylib`, or a minos below the target minimum;
  - a Windows import of `VCRUNTIME*` or `MSVCP*`.
- **D-I. Release and publish chain:**
  - A tag `frustbite-v<version>` (renamed from `frustbite-assets-v…`) builds and verifies all 12 targets and the wasm, then creates the GitHub Release with the 12 libraries, `frustbite.wasm`, `THIRD_PARTY_LICENSES.md` and `checksums.json`.
  - It also stages the package and runs `dart pub publish --dry-run` on the staged copy.
  - Publishing itself stays manual, by the author.
  - `tool/stage_package.dart --from-release <tag> | --from-dir <dir> --out <dir>` builds the staged package. It copies the git-tracked `packages/frustbite` files, `native/` into `rust/` (no `target/`, with `Cargo.lock`), the prebuilt files into `prebuilt/<target>/<one name>`, and writes `checksums.json`. It fails with fewer than 12 libraries.
  - `tool/check_pubignore.dart`: the staged `.pubignore` must not exclude `prebuilt/` or `rust/`, and must exclude `rust/target/`.
- **D-J. Version 0.0.2.** The package is not on pub.dev yet. CHANGELOG `## 0.0.2` describes the distribution change. PR #4 (hashes for 0.0.1) is superseded.
- **D-K. iOS privacy manifest.** Check the iOS dylib with `nm -u` for `stat`, `fstat`, `lstat`, `fstatat` and `getattrlist`. If any are present, document in the README which `NSPrivacyAccessedAPICategoryFileTimestamp` reason the app should declare, as ws does. Otherwise state that none is needed.
- **D-L. Docs:**
  - `docs/DECISIONS.md`: the stage 1 rulings R1–R27 (from the PR history and README) plus D-A…D-K.
  - `docs/ROADMAP.md`: stages 2–5 and the open follow-ups (Android API 30 → lower, per-OS user-define polish, `dart compile exe` path via a CLI install command in stage 4).
  - `mise.toml`: tasks fmt, analyze, test, check, build:native, verify:native, stage, publish:check.
  - README and docs: the new distribution, offline builds, `source`/`library`/`formats`, glibc 2.17, privacy manifest.

## Global Constraints
- Pure Rust; licenses MIT, Apache-2.0, BSD, Zlib, MPL-2.0. No new runtime crates.
- Never hand-edit generated files (bindings.dart, enums.dart, frustbite.h, THIRD_PARTY_LICENSES).
- ABI unchanged. The library file name change does not change the ABI.
- `main` is protected. Work lands through a PR, with CI green.
- Do not push or tag without the author's OK. Do not publish to pub.dev.

## Review Focus
1. **A tampered or corrupt bundled library** fails with a clear checksum error, never loads.
2. **No cargo on PATH and no prebuilt for the target** gives a clear error naming the `source` options, not a stack trace.
3. **Universal macOS and iOS-simulator Flutter builds** show no framework-name warning, and both architectures load.
4. **A user's `RUSTFLAGS`** can't remove the 16 KB / install-name flags.
5. **A hook re-run with nothing changed** does not rebuild or re-run cargo.

---

### Task 1: Portable binaries (build.rs, zigbuild, verify script)
**Files:**
- Create `native/build.rs` and `tool/verify_native.sh` (repo root `tool/`).
- Modify `native/.cargo/config.toml`, `native/Cargo.toml` (`build = "build.rs"` if needed), `.github/workflows/build_release.yaml` (zigbuild on Linux, verify step on every build, Linux runners back to `ubuntu-latest`), `packages/frustbite/tool/build.dart` (use zigbuild for linux targets when requested, and output the single file name in a `<target>/` subdirectory).
- [ ] Write `build.rs` per D-F. Move the Windows CRT setting into the config and remove the Android rustflags.
- [ ] Write `verify_native.sh` per D-H. Run it locally on the macOS and iOS outputs of `dart tool/build.dart` and record the output. The expected export count is however many `frustbite_` functions `nm` shows today. Make it a constant in the script.
- [ ] CI: Linux uses `pip install ziglang` plus `cargo install cargo-zigbuild --locked` (pinned versions), with the glibc 2.17 target suffix. Every build job runs `verify_native.sh`. Output layout: `libs/<target>/<one name>`. The artifact keeps that layout.
- [ ] Run `actionlint`, `cargo test`, `cargo clippy`, and `dart test` in packages/frustbite. Commit.

### Task 2: Hook resolution (bundled prebuilt, cargo fallback, user defines)
**Files:**
- Rewrite `packages/frustbite/hook/build.dart` and `lib/src/hook/local_build.dart`.
- Add `lib/src/hook/resolve.dart` (pure functions: source parsing, target dir names, the crate lookup, the checksum check).
- Delete `download_asset.dart`, `hashes.dart` and `version.dart`. Keep `targets.dart` for the names, with directory names `<os>-<arch>[-sim]`.
- Update `test/hook_test.dart`.
- Update `.gitignore`: `packages/frustbite/prebuilt/`.
- [ ] Tests first:
  - `source` parsing: string, per-OS map, unknown value → error, `local_build` alias, `formats` → build;
  - the target directory name for all 12 targets;
  - one file name per OS;
  - the checksum check: match, mismatch (error mentions corruption), missing `checksums.json` next to a prebuilt (error);
  - crate lookup: `rust/` first, then `../../native/`, then none;
  - the cargo target key includes the NDK API / deployment version;
  - the dependencies list holds only existing files.
- [ ] Implement per D-C/D-D/D-E. The workspace (`local_build: true`) must still build from source, so the existing `dart test` keeps passing.
- [ ] Manual check, recorded in the report:
  - Put a locally built `macos-arm64/libfrustbite.dylib` and a `checksums.json` in `packages/frustbite/prebuilt/`.
  - Run the scratch app (path dependency, no `local_build`, no cargo on PATH). It must load the bundled file.
  - Corrupt one byte: it must fail with the checksum error.
- [ ] Commit.

### Task 3: Staging, release chain, version 0.0.2
**Files:**
- Create `packages/frustbite/tool/stage_package.dart` and `packages/frustbite/tool/check_pubignore.dart`.
- Modify `.github/workflows/build_release.yaml` (tag `frustbite-v*`; preflight checks against pubspec and CHANGELOG; the release adds `checksums.json`; a stage + `pub publish --dry-run` job), `packages/frustbite/pubspec.yaml` (version 0.0.2; `false_secrets: [prebuilt/**]` if the dry-run flags binaries), `CHANGELOG.md` (`## 0.0.2`) and `.pubignore`.
- [ ] Tests: `stage_package` against a fake dir with 12 dummy libraries produces the layout and checksums. It fails with 11. The staged copy has no `test/fixtures` and no `rust/target`, and does have `rust/Cargo.lock`.
- [ ] Locally: stage from a dir holding real macOS and iOS builds plus dummy files for the rest, then run `dart pub publish --dry-run` in the staged dir. Record the archive size and warnings.
- [ ] Run `actionlint`. Commit.

### Task 4: Docs, decisions, roadmap, mise
**Files:**
- Create `docs/DECISIONS.md`, `docs/ROADMAP.md` and `mise.toml`.
- Modify both READMEs, `docs/content/01-getting-started.mdx`, `docs/content/04-formats-and-build.mdx`, `AGENTS.md` and `CONTRIBUTING.md`.
- [ ] Check the privacy manifest per D-K, using `nm -u` on the iOS dylib from Task 1's local build.
- [ ] Write the docs per D-L. Remove every mention of download-at-build-time and of the R25 git-only limitation. Document `source`/`library`/`formats`, offline builds, glibc 2.17, the single file name, and how to verify integrity.
- [ ] Run `npm run docs:build && npm run docs:check`, check links, and commit.
