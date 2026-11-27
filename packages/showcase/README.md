# Frustbite showcase

Minimal Flutter app for frustbite: open an audio file (or one of the bundled
samples) and see its codec info, tags, cover art and a waveform.

The package depends on `../frustbite` and builds the Rust library locally
(`hooks.user_defines.frustbite.local_build: true`), so a Rust toolchain is required.

```bash
flutter run -d macos
flutter run -d <ios-simulator-id>   # see `flutter devices`
flutter test
```

## Web

Build the wasm module and place it in `web/` (it is git-ignored):

```bash
cd ../frustbite && dart tool/build_wasm.dart ../showcase/web/frustbite.wasm
cd ../showcase && flutter run -d chrome
```

The app calls `Frustbite.initialize()` at start-up, which loads `frustbite.wasm`.

## macOS

The sandbox entitlements include `com.apple.security.files.user-selected.read-only`
so that "Open file" can read the picked file.

## Samples

`assets/demo.mp3` and its cover (drawn from its own waveform) are synthesised by
`tool/generate_demo.sh` (needs ffmpeg) and are released under CC0. `tone.*` are the library's test fixtures.
