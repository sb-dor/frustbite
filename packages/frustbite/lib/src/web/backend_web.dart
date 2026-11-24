import 'dart:typed_data';

import '../audio_enums.dart';
import '../audio_info.dart';
import '../audio_pcm.dart';
import '../audio_tags.dart';
import '../waveform.dart';

/// Web backend; implemented in a later task.
final class BackendAudio {
  static int get abiVersion => throw UnimplementedError('web backend');

  static Future<void> initialize({Uint8List? wasmBytes, Uri? wasmUri}) =>
      throw UnimplementedError('web backend');

  factory BackendAudio.fromMemory(Uint8List bytes, AudioContainer? format) =>
      throw UnimplementedError('web backend');

  factory BackendAudio.fromFile(String path, AudioContainer? format) =>
      throw UnsupportedError('fromFile is not available on web');

  int get sourceByteLength => throw UnimplementedError('web backend');
  AudioInfo info() => throw UnimplementedError('web backend');
  AudioTags tags() => throw UnimplementedError('web backend');
  AudioCover? cover() => throw UnimplementedError('web backend');
  Waveform waveform(int buckets, WaveformMode mode, bool perChannel) =>
      throw UnimplementedError('web backend');
  AudioPcm decode() => throw UnimplementedError('web backend');
  void dispose() => throw UnimplementedError('web backend');
}
