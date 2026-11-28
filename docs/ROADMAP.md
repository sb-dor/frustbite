# Roadmap

Stage 1 (reading), distribution v2 (version 0.0.2: bundled prebuilt
libraries, offline hermetic builds) and stage 2 (editing, version 0.0.3) are done. The rulings behind them are in
[DECISIONS.md](DECISIONS.md). Each stage ends in a working state, with tests
green on every CI target.

## Stages

### Stage 2: Editing (done, 0.0.3)

`trim`, `concat` with crossfades, `gain`, `normalize`, `fadeIn`/`fadeOut`,
`resample`, `toMono`/`toStereo`, `trimSilence`, `detectSilence` and `mix`, as a
lazy pipeline that runs in one native call, plus WAV writing (E-A to E-H in
DECISIONS). The benchmark package has resampling, editing and WAV encoding
rows.

Follow-ups left for later: loudness normalization (`normalizeLoudness`, LUFS),
`reverse`, `pad`, channel selection, and streaming edits for large files
(stage 4).

### Stage 3: Writing

Encoders for flac and opus (wav is written since stage 2), with `encode` and `saveToFile`, and tag
writing without re-encoding. Tags are rewritten through `lofty`, and the result
goes to a **new** file by default (`writeTags(tags, to: path)`). Changing the
source file needs an explicit `inPlace: true`, which writes a temporary file and
replaces the original atomically, so a failure never damages the user's data.
Error code 7 (`EncodingError`) is reserved for this stage.

### Stage 4: Large files and CLI

Streaming decode as a `Stream` of PCM chunks, a `frustbite info|waveform|convert|trim`
command line tool, and docs for every section. The CLI is installed with a
command (see the `dart compile exe` item below).

### Stage 5: Publishing

First release of the binaries, `dart pub publish --dry-run`, and the publish to
pub.dev, with the author's confirmation. The package can be published earlier,
after stage 1, if the author wants it. The release chain (tag
`frustbite-v<version>`, staged package, manual publish) already exists; see
CONTRIBUTING.

## Open items

- **A player package.** frustbite does not play audio; apps hand `toWav()`
  bytes to a player package, and the showcase uses `audioplayers`. A separate
  package on the same Rust core (for example `frustbite_player`) would let
  apps play without a third-party player. The `frustbite` package itself stays
  free of dependencies.
- **Android minimum below API 30.** The NDK pin and the 16 KB alignment set
  API 30 today (R27). Lowering it needs a CI verification that the libraries
  load on an older emulator image.
- **First real CI run of the new release chain.** The Windows branch of
  `verify_native.sh` (no VC++ runtime import) and the zig / cargo-zigbuild
  install on the Linux runners have not run on real runners yet; the first
  pull request run will show them.
- **A `dart compile exe` path.** `dart compile exe` cannot use packages with
  build hooks. Stage 4's CLI gets an install command (as ws does with
  `dart run ws:install`) that builds the executable with the hook's output.
- **Per-OS user-define docs polish.** The per-OS `source` map is documented
  with one example; add examples for CI (a Linux runner that builds, desktop
  that uses the bundled library).
- **Dependency bumps.** Open Dependabot PR #2 bumps `blume` from 1.6.1 to 2.2.7
  in `docs/`, a major version that needs a docs build check. The
  `cupertino_icons` 2.0.0 bump is merged. `symphonia`, `symphonia-core` and
  `opus-pure` stay pinned on purpose (R13, R14). PR #4 (hashes for 0.0.1) is
  superseded by D-B and should be closed.
- **iOS privacy manifest.** Re-run `nm -u` on the iOS libraries when the Rust
  dependencies change (D-K).
