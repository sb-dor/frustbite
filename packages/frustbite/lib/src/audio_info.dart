import 'audio_enums.dart';

/// Description of an opened audio source.
final class AudioInfo {
  const AudioInfo({
    required this.container,
    required this.codec,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.bitrate,
    required this.totalFrames,
    required this.duration,
  });

  final AudioContainer container;
  final AudioCodec codec;

  /// Sample rate in Hz.
  final int sampleRate;
  final int channels;

  /// Bits per sample for PCM, FLAC and ALAC; null when not applicable.
  final int? bitsPerSample;

  /// Average bitrate in bits per second; null when unknown.
  final int? bitrate;

  /// Playable frames per channel.
  final int totalFrames;
  final Duration duration;

  @override
  String toString() =>
      'AudioInfo($container, $codec, $sampleRate Hz, $channels ch, '
      '$totalFrames frames, $duration)';
}
