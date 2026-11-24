import 'dart:typed_data';

/// Fully decoded audio: interleaved f32 samples.
final class AudioPcm {
  const AudioPcm({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  /// Interleaved samples (frames x channels).
  final Float32List samples;
  final int sampleRate;
  final int channels;

  /// Frames per channel.
  int get frames => channels == 0 ? 0 : samples.length ~/ channels;

  Duration get duration => sampleRate == 0
      ? Duration.zero
      : Duration(
          microseconds: frames * Duration.microsecondsPerSecond ~/ sampleRate,
        );
}
