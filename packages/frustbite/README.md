# frustbite

[![CI](https://github.com/sb-dor/frustbite/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/sb-dor/frustbite/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/sb-dor/frustbite/blob/main/LICENSE)
[![Docs](https://img.shields.io/badge/docs-sb--dor.github.io%2Ffrustbite-informational)](https://sb-dor.github.io/frustbite/)
[![pub package](https://img.shields.io/pub/v/frustbite.svg)](https://pub.dev/packages/frustbite)

<img src="https://raw.githubusercontent.com/sb-dor/frustbite/main/packages/frustbite/doc/showcase.webp" alt="frustbite: the showcase app on iPhone in light and dark mode, with stream info, tags, cover art and a waveform, next to an editing example" width="100%">

Read and edit audio from pure Dart: stream info, tags, cover art, waveforms and
decoded PCM; trim, join, mix, fade, normalize, resample and save as WAV. A Rust
crate does the work through FFI and Dart build hooks on native platforms and
through WebAssembly on the web.

Full documentation: <https://sb-dor.github.io/frustbite/>.

## Why frustbite

Playing audio in Flutter is easy, but doing anything else with it is not:
reading its length and tags, drawing its waveform, cutting it or converting it.
The usual answer has been FFmpeg, and FFmpegKit, the common FFmpeg wrapper for
Flutter, was retired in 2025 (community forks carry on). FFmpeg adds tens of
megabytes to an app, does not run on the web, and is licensed under the LGPL or
GPL. The other option is a separate plugin for each task, often for Android
and iOS only.

frustbite does these jobs in one package:

- one Dart API on Android, iOS, macOS, Windows, Linux and the web;
- a native library of about 2 to 4 MB per platform;
- MIT license, and no dependencies on other Dart packages;
- plain Dart, so it also runs on a server or in a command line tool, not only
  in Flutter.

What people use it for:

| Task | What frustbite gives you |
| --- | --- |
| Voice messages in a chat app | the waveform bars and the duration |
| A podcast or music app | tags, cover art and duration without playing the file; a waveform for the seek bar |
| Speech recognition (Whisper and similar) | the 16 kHz mono WAV these models expect: `edit().toMono().resample(16000).toWav()` |
| Trimming before upload (social apps, ringtones) | trim, fades and normalization on the device |
| An audio editor | joins with crossfades, mixing, silence removal |
| Opus or Vorbis on iOS | convert to WAV and hand it to any player; iOS does not play them from Ogg or WebM |
| Processing on a server | the same code in a Dart backend |

## What frustbite does not do

frustbite reads and edits audio. It does not:

- **Play audio.** It has no player and no audio output. Use a player package
  such as [`audioplayers`](https://pub.dev/packages/audioplayers),
  [`just_audio`](https://pub.dev/packages/just_audio) or
  [`media_kit`](https://pub.dev/packages/media_kit) and hand it the WAV bytes
  from `toWav()`. Converting first also lets a player play formats its
  platform cannot decode, such as Opus or Vorbis on iOS.
- **Record.** It has no microphone input. Record with another package, then
  open the file or bytes with frustbite.
- **Encode compressed formats yet.** Output is WAV. FLAC and Opus encoders and
  tag writing are on the [roadmap](#roadmap); for why there is no MP3 or AAC
  output, see [Output formats](#output-formats-wav-flac-opus-mp3-and-aac).
- **Open URLs.** It takes a file path or bytes, so download the file first.

Playing an edit with `audioplayers`:

```dart
import 'package:audioplayers/audioplayers.dart';
import 'package:frustbite/frustbite.dart';

Future<void> preview(Frustbite song, AudioPlayer player) async {
  final wav = await song
      .edit()
      .trim(end: const Duration(seconds: 30))
      .fadeOut(const Duration(seconds: 2))
      .toWavAsync();
  await player.play(BytesSource(wav, mimeType: 'audio/wav'));
}
```

## Output formats: WAV, FLAC, Opus, MP3 and AAC

frustbite reads all of these formats (see [Formats](#formats)). This section is
about **saving**, which today means WAV.

| Format | Compression | One minute of stereo | Quality | Plays everywhere? |
| --- | --- | --- | --- | --- |
| **WAV** | none | about 10 MB | the original | yes |
| **FLAC** | lossless | about 5 to 6 MB | the original | almost everywhere |
| **MP3** | lossy | about 1 MB at 128 kbps | good | yes |
| **AAC** | lossy | about 1 MB | better than MP3 | yes |
| **Opus** | lossy | about 0.5 to 1 MB | the best per kilobyte | not well on Apple platforms |

- **WAV** is sound with no compression: a 44-byte header that says, for
  example, "stereo, 44100 Hz, 16-bit", then the samples one after another.
  Almost every device, browser and player plays a 16-bit WAV. That is what
  `toWav()` and `saveWav()` write by default (`WavFormat.pcm16`); the 24-bit
  and float formats are for studio work, and some simple players cannot play
  them.
- **FLAC** is "WAV in a zip file": lossless, about half the size, and it
  unpacks to exactly the same samples. It is used for high-quality music and
  archives.
- **Opus** is a modern lossy format designed for the internet, used for voice
  messages in WhatsApp and Telegram, calls in Discord and WebRTC, and audio on
  YouTube. Speech stays clear at 16 to 24 kbps. Apple platforms play it only
  in some containers.

Converting an MP3 to WAV is one line, `Frustbite.fromFile('song.mp3').saveWav('song.wav')`,
and works the same for every format frustbite reads. It does not bring back
what the MP3 lost; it keeps the sound exactly as it is, in a file about ten
times bigger. So WAV is best as a step in between: to hand to a player, to feed
to a speech model, or to keep the result of an edit without losing more.

### Why WAV first

WAV needs no encoder. frustbite writes it by hand in about 130 lines of Rust,
with no dependency. It loses nothing, so an edit can be saved and edited again
any number of times without getting worse. And `render()` gives back a normal
`Frustbite` held as a float WAV in memory, so every method works on the result.

### Why no MP3 or AAC output

Reading a format needs a decoder; saving it needs an encoder, and a good one
is a big piece of work: it models what the ear cannot hear and throws that
away. LAME, the standard MP3 encoder, took more than 20 years to mature. The
existing encoders do not fit frustbite's rules: the core is pure Rust, so it
builds for 12 native targets and for WebAssembly, and its dependencies are
MIT, Apache-2.0, BSD, Zlib or MPL-2.0, so any app can use it without licensing
trouble.

- **MP3.** The patents expired in 2017, so the format is free to use. The
  encoders are the problem: LAME is C under the LGPL, and the Rust MP3
  encoders are either LGPL too (`shine-rs`) or too new to judge.
- **AAC.** There is no mature pure-Rust AAC encoder; the good ones are C
  (`fdk-aac` under its own non-free license, `libxaac`). AAC is also still
  licensed through a patent pool.

The plan is FLAC and Opus first, since pure-Rust encoders with fitting licenses
exist for both. MP3 can follow once a good pure-Rust encoder does. AAC is
further off, most likely through the encoders the operating systems ship
(Apple, Android and Windows have one; Linux does not). Until then, an app can
take the WAV from frustbite and compress it with a platform encoder or another
package.

## Showcase

The [Flutter showcase](https://github.com/sb-dor/frustbite/tree/main/packages/showcase),
pictured at the top, opens an audio file or a bundled sample and shows its
stream info, tags, cover art and waveform. Its editor trims, fades, normalizes,
resamples and converts to mono, plays the source and the result, and saves the
result as WAV. The showcase plays audio with `audioplayers`; frustbite itself
has no dependency on it.

## Install

```yaml
dependencies:
  frustbite: ^0.0.5
```

The package carries the prebuilt native library for every native target (12
in all) in its `prebuilt/` directory, and the build hook picks the one for your
target. The build is offline and hermetic: nothing is downloaded, no Rust
toolchain is needed, and the hook verifies each library against the SHA-256 in
`prebuilt/checksums.json` before it is used. Supported platforms: Android, iOS,
Linux (glibc-based distributions with glibc ≥ 2.17; not musl), macOS, Windows
and the web.

## Platform requirements

The prebuilt binaries target these minimum OS versions:

| Platform | Minimum |
| --- | --- |
| iOS | 16.0 |
| macOS | 13.0 |
| Android | API 30 (Android 11) |
| Linux | glibc-based distributions with glibc ≥ 2.17 (CentOS 7 and newer); musl distributions such as Alpine are not supported |

A Flutter app has to raise its own minimums to match, or the build fails or the
app does not load the library:

- **iOS**: in `ios/Podfile` set `platform :ios, '16.0'`, and set the iOS
  Deployment Target of the Runner target to 16.0 in Xcode.
- **macOS**: in `macos/Podfile` set `platform :osx, '13.0'`, and set
  `MACOSX_DEPLOYMENT_TARGET = 13.0` (Xcode: macOS Deployment Target).
- **Android**: in `android/app/build.gradle(.kts)` set `minSdk = 30`
  (`minSdkVersion 30` in older Groovy files).

Windows binaries link the C runtime statically, so no Visual C++
Redistributable is needed. For other minimums, build from source (see
[Build options](#build-options)).

### iOS privacy manifest

Apple requires an app to declare the "required reason" APIs that its code, and
the libraries in it, call. The iOS libraries import `stat` and `fstat` (from the
Rust standard library, to open a file and read its size), which Apple lists
under the **file timestamp** category. The library never reads or exposes a
timestamp, but Apple matches on the API, not on how it is used. No other
required-reason API is imported: not `getattrlist`, `mach_absolute_time` or the
disk space calls (`statfs`, `statvfs`). A pure Dart package cannot ship a
`PrivacyInfo.xcprivacy` of its own, so the app declares the reason in its
`ios/Runner/PrivacyInfo.xcprivacy`. Put this fragment inside the top-level
`<dict>` of that file:

```xml
<key>NSPrivacyAccessedAPITypes</key>
<array>
  <dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array>
      <!-- files inside the app container (bundled or downloaded assets) -->
      <string>C617.1</string>
      <!-- files the user picked, for example with a document picker -->
      <string>3B52.1</string>
    </array>
  </dict>
</array>
```

Declare only the reasons that match what your app does: `C617.1` if it opens
audio files in its own container, `3B52.1` if it opens files the user granted
access to. Third-party-SDK reason `0A2A.1` is for SDK code and does not fit an
app that calls Frustbite. macOS needs no manifest.

## Quick start

```dart
import 'package:frustbite/frustbite.dart';

void main() {
  final audio = Frustbite.fromFile('song.mp3');
  try {
    final info = audio.info;
    print('${info.codec.name}, ${info.sampleRate} Hz, ${info.duration}');
    print('${audio.tags.artist} - ${audio.tags.title}');

    final waveform = audio.waveform(buckets: 200);
    print(waveform.channel(0).length); // 200 amplitudes in [0, 1]

    final pcm = audio.decode(); // interleaved Float32List
    print(pcm.frames);
  } finally {
    audio.dispose();
  }
}
```

A runnable version lives in [`example/frustbite_example.dart`](example/frustbite_example.dart):

```sh
dart run example/frustbite_example.dart song.mp3
```

Use `Frustbite.fromMemory(bytes)` on every platform, including the web. The
container is detected from the content; the optional `format:` argument is only
an advisory hint, and a wrong hint is not an error.

## Formats

| Codec | Containers |
| --- | --- |
| MP3 | MP3 |
| AAC-LC | MP4/M4A, ADTS |
| ALAC | MP4/M4A |
| FLAC | FLAC |
| Vorbis | Ogg |
| Opus | Ogg, WebM/Matroska |
| PCM | WAV |

Known limitations:

- **HE-AAC** (HE-AAC and HE-AACv2) is unsupported. It throws
  `UnsupportedFormatException` when SBR is signalled explicitly. Implicit-SBR
  and ADTS HE-AAC cannot be detected when the file is opened and may decode as
  the AAC-LC core.
- **Opus in MP4** is unsupported in stage 1. Opus in Ogg and in WebM/Matroska
  is supported.
- **WebM** gives no tags (the tag library has no Matroska support). Its
  duration may include up to one packet of tail padding.
- **m4a and ADTS**: `totalFrames` includes the 1024-frame AAC priming. It is
  exact for wav, flac, mp3 with a LAME/Xing header, vorbis, ogg-opus and alac;
  mp3 without that header is counted from the packets.
- **ID3v1 text** is decoded as Latin-1, so non-Latin titles in ID3v1-only files
  (for example CP1251 Cyrillic) show as mojibake. ID3v2 tags are unaffected.

## Async

`waveformAsync` and `decodeAsync` run on a background isolate on native
platforms, so the UI isolate stays free. On the web they only defer the work to
a later event-loop turn; it still runs on the main thread.

```dart
final waveform = await audio.waveformAsync(buckets: 200);
```

## Editing

`edit()` starts a lazy chain of operations; a terminal call runs it in one
native call and never changes the source:

```dart
final voice = Frustbite.fromFile('voice.m4a');
final clean = voice
    .edit()
    .trimSilence()
    .fadeIn(const Duration(milliseconds: 200))
    .fadeOut(const Duration(milliseconds: 500))
    .normalize()
    .render(); // a new Frustbite; or toWav() / saveWav(path)
clean.saveWav('voice.wav');
clean.dispose();
voice.dispose();
```

Operations: `trim`, `gain`, `normalize`, `fadeIn`, `fadeOut`, `resample`,
`toMono`, `toStereo`, `trimSilence`, `append` (with an optional crossfade) and
`mix`; `Frustbite.concat([...], crossfade: ...)` joins several sources, and
`detectSilence()` finds the pauses. `toWav`/`saveWav` write 16-bit, 24-bit or
32-bit float WAV, so `audio.toWav()` also converts any supported format to WAV.
Every terminal has an async form (`renderAsync`, `toWavAsync`,
`saveWavAsync`). Editing works in memory; see the
[Editing guide](https://sb-dor.github.io/frustbite/editing) for the semantics
of each operation.

## Web

Download `frustbite.wasm` from the GitHub Release `frustbite-v<version>`
matching the package version (for example `frustbite-v0.0.5`) and put it in the
web root, then initialize before first use:

```dart
await Frustbite.initialize();
final audio = Frustbite.fromMemory(bytes);
```

`fromFile` and `saveWav` throw `UnsupportedError` on the web (use `toWav`). On pages whose CSP forbids
`unsafe-eval`, a Rust panic inside wasm under dart2wasm escapes as a raw
JavaScript error instead of `UnknownFrustbiteException`.

## Build options

By default (`source: auto`) the hook uses the bundled library. The build is
offline and hermetic: no network access and no Rust toolchain are needed, and
the hook rejects any library whose SHA-256 differs from `prebuilt/checksums.json`
with a "checksum mismatch" error (clear the pub cache entry and reinstall). To
check by hand, hash a file under `prebuilt/` and compare it with its entry in
that JSON. Every target ships one file name (`libfrustbite.so`,
`libfrustbite.dylib` or `frustbite.dll`), and only the directory
(`prebuilt/<os>-<arch>[-sim]/`) tells the targets apart.

Set user defines in your application's `pubspec.yaml`. The hook resolves the
library in this order:

1. `library: <path>` uses that file as is. It must exist. The file is unchecked: it gets no checksum and no build-time ABI check (only the runtime ABI check at the first call), `formats` cannot be combined with it, and a relative path resolves against the directory of the `pubspec.yaml` that sets the define, not the working directory.
2. `source` picks where the library comes from:
   - `auto` (default): the bundled library if there is one, else `cargo build`
     if the Rust crate and cargo are present, else a `StateError` that lists
     these options.
   - `prebuilt`: only the bundled library; an error if it is missing.
   - `build`: only `cargo build --release --locked` of the Rust crate.
   - `none`: add no library. The app then fails at the first Frustbite call
     with the "missing native library" error.
3. `formats` and `local_build: true` both mean `source: build`.

```yaml
hooks:
  user_defines:
    frustbite:
      # Your own build of the library; takes precedence over `source`.
      # library: /opt/frustbite/libfrustbite.so
      source: build
      # Optional, implies a source build: compile only these codecs.
      # Names: aac, alac, flac, mp3, opus, vorbis, wav.
      formats: [mp3, wav]
```

`source` also takes a map per OS, with an optional `default`. Keys are Dart OS
names (`android`, `ios`, `linux`, `macos`, `windows`); an unknown key or value is
an error, never a silent `auto`:

```yaml
hooks:
  user_defines:
    frustbite:
      source:
        default: prebuilt
        linux: build
```

Source builds work from the pub.dev package too: it carries the crate in
`rust/` (a repository checkout or git dependency uses `native/`). The hook
finds `cargo` on `PATH`, then in `$CARGO_HOME/bin`, then in `~/.cargo/bin`.
The crate pins its toolchain (`rust-toolchain.toml`), which rustup installs on
the first build.

## Prebuilt binaries

- Linux: built with `cargo zigbuild` against glibc 2.17, with libgcc linked
  statically; CI fails a build that needs a newer glibc. musl distributions
  such as Alpine are not supported.
- Android: 16 KB page-aligned; Apple: `@rpath/libfrustbite.dylib` install
  name; Windows: static C runtime.
- Every library passes `tool/verify_native.sh` in CI before a release.

## Performance

On an Apple M3 Pro, 180 s of 44.1 kHz stereo mp3 decodes in 98 ms. That is
roughly on par with the native `audio_decode` (0.91x) and 81x faster than the
pure-Dart `glint_audio_pure`. Resampling the same length to 48 kHz takes 176 ms. See [`packages/benchmark`](https://github.com/sb-dor/frustbite/blob/main/packages/benchmark/README.md)
for the full table, including the rows where Frustbite is slower.

## Roadmap

1. **Reading (0.0.2).** `fromFile`/`fromMemory`, `info`, `tags`,
   `cover`, `waveform`, `decode` and their async variants; web support.
2. **Editing (0.0.3).** `trim`, `concat` with crossfades, `gain`,
   `normalize`, `fadeIn`/`fadeOut`, `resample`, `toMono`/`toStereo`,
   `trimSilence`, `detectSilence` and `mix`, as a lazy pipeline run in one
   native call; WAV writing.
3. **Writing.** flac and opus encoders, `encode` and `saveToFile`, and
   tag writing without re-encoding.
4. **Large files and CLI.** Streaming decode as a `Stream` of PCM chunks and a
   `frustbite info|waveform|convert|trim` command line tool.
5. **Publishing.** First stable release with prebuilt binaries for all targets.

## License

See [LICENSE](LICENSE). Third-party notices are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md); note that the bundled
`symphonia` decoders are MPL-2.0, and that file says where to get their source.

## Acknowledgements

Repository structure, build hooks and release flow adapted from
[hawkkiller/pixer](https://github.com/hawkkiller/pixer) (MIT, © 2026 Michael
Lazebny).
