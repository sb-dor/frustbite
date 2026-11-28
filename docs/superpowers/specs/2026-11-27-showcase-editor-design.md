# Showcase editor design

Date: 2026-11-27. Size: a small change (the showcase app and READMEs only).

## Intent

The showcase today only reads a file. People should be able to use it on their
own files: load one, edit it with frustbite's pipeline, listen to the result
and save it as WAV. It also shows off the editing API, frustbite's main feature.

## Goals

- An editor screen, opened for the loaded file, with trim, fades, normalize,
  mono, trim silence and resample.
- Waveforms before and after, playback of both, and Save as WAV.
- Works on every platform the showcase has a runner for today (Android, iOS,
  macOS, web); `audioplayers` also covers Windows and Linux if runners are
  added.
- The READMEs say plainly what frustbite does and that it does not play audio,
  and point to player packages.

## Non-goals and anti-goals

- No new dependency for the `frustbite` package. Anything for playback goes in
  the showcase only (`publish_to: none`).
- No player inside frustbite now. The author wants an own player later, as a
  separate package (`frustbite_player` or similar) on the same Rust core; it is
  noted on the roadmap, not built here.
- No live re-render on every slider move: long files would stutter.
- No multi-file editing (append, mix, concat) in this screen.

## Approaches

1. **`audioplayers` in the showcase (picked).** Plays bytes on all six
   platforms (`BytesSource`; on iOS, macOS and Linux it writes a temp file
   itself). Showcase-only dependency. Linux needs GStreamer at run time; CI only
   runs `flutter analyze` and `flutter test`, so CI needs nothing new.
2. **No playback.** No dependency, but every edit must be saved and opened
   elsewhere to be heard. Rejected: not usable for real work.
3. **Own player in frustbite.** Rejected for now: per-platform output, audio
   sessions and focus, a new public API and a bigger binary for every user.
   Moved to the roadmap as a separate package.

`just_audio` was dropped: Windows and Linux need extra packages.

## Design

- **Entry.** An "Edit" button on the main page once a file is loaded pushes
  `EditorPage` with the file name and its `Frustbite` (still owned by the main
  page).
- **Selection.** The source waveform with two draggable handles for trim start
  and end, and their times shown below. Defaults to the whole file.
- **Operations**, applied in this order: trim (handles), trim silence (switch),
  fade in and fade out (sliders, 0 to 5 s, limited to the selection length),
  mono (switch), resample (dropdown: original, 8, 16, 22.05, 44.1, 48 kHz),
  normalize (switch, peak −1 dB).
- **Apply** runs `renderAsync()` and shows the result: its waveform, duration,
  sample rate and channels. Changing a control after that marks the result as
  stale until the next Apply.
- **Playback.** Play/stop for the source and for the result. Both play WAV
  bytes from `toWavAsync()`, so formats a platform cannot play itself (Opus and
  Vorbis on iOS, for example) still play. The playback position is drawn as a
  line on the waveform.
- **Save.** A WAV format dropdown (16-bit, 24-bit, float) and "Save WAV":
  `toWavAsync(format:)` on the result, then `FilePicker.saveFile(fileName:
  '<name>-edited.wav', bytes:, mimeType: 'audio/wav')`. Cancelling does nothing;
  a failure shows a SnackBar.
- **Lifetime.** The editor disposes its rendered results and its player. The
  source is not disposed by the editor.
- **macOS.** The entitlement becomes `files.user-selected.read-write` so Save
  can write.
- **Tests.** Playback goes through a small interface so widget tests use a fake
  instead of the plugin. A widget test loads `demo.mp3`, opens the editor,
  applies a trim with fades and checks the result duration; another checks
  Save hands WAV bytes to the save function (also injected).

## README changes

- `packages/frustbite/README.md` (pub.dev) and the root `README.md` get a short
  "What frustbite does not do" part: no playback, no recording, no compressed
  encoding yet (roadmap). For playback, use a player package such as
  `audioplayers`, `just_audio` or `media_kit`, and hand it `toWav()` bytes, with
  a short `audioplayers` example.
- The showcase README and the Showcase sections describe the editor and the
  `audioplayers` dependency.
- `docs/ROADMAP.md` gets the future player package as an open item.

## Left to the builder

Layout details, the handle widget, labels and icons, and how the result card
looks, as long as they follow the existing Material 3 teal theme.
