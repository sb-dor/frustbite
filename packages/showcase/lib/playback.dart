import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Plays WAV bytes. frustbite itself does not play audio, so the showcase uses
/// the `audioplayers` package behind this interface; tests use a fake.
abstract interface class Playback {
  /// The position of the sound that is playing.
  Stream<Duration> get position;

  /// Fires when a sound plays to its end.
  Stream<void> get completed;

  Future<void> playWav(Uint8List bytes);

  Future<void> stop();

  Future<void> dispose();
}

/// Creates the [Playback] an editor uses; it is disposed with the editor.
typedef PlaybackFactory = Playback Function();

/// Lets the user save [bytes] as [fileName]. Returns false when cancelled.
typedef SaveFile = Future<bool> Function(String fileName, Uint8List bytes);

Playback audioPlayersPlayback() => _AudioPlayersPlayback();

Future<bool> saveWithFilePicker(String fileName, Uint8List bytes) async {
  final uri = await FilePicker.saveFile(
    fileName: fileName,
    bytes: bytes,
    mimeType: 'audio/wav',
  );
  return uri != null;
}

class _AudioPlayersPlayback implements Playback {
  final _player = AudioPlayer();

  @override
  Stream<Duration> get position => _player.onPositionChanged;

  @override
  Stream<void> get completed => _player.onPlayerComplete;

  @override
  Future<void> playWav(Uint8List bytes) async {
    await _player.stop();
    await _player.play(BytesSource(bytes, mimeType: 'audio/wav'));
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}
