import 'dart:typed_data';

/// Amplitude summary for drawing, channel-major.
final class Waveform {
  Waveform({required this.data, required this.buckets, required this.channels});

  /// `buckets * channels` values: all buckets of channel 0, then channel 1...
  final Float32List data;
  final int buckets;
  final int channels;

  /// The buckets of channel [i] as a view into [data].
  Float32List channel(int i) {
    RangeError.checkValidIndex(
      i,
      List<void>.filled(channels, null),
      'i',
      channels,
    );
    return Float32List.sublistView(data, i * buckets, (i + 1) * buckets);
  }

  /// A copy scaled so the maximum is 1. An all-zero waveform is returned unchanged.
  Waveform normalized() {
    var max = 0.0;
    for (final v in data) {
      if (v > max) max = v;
    }
    if (max == 0) return this;
    final out = Float32List(data.length);
    for (var i = 0; i < data.length; i++) {
      out[i] = data[i] / max;
    }
    return Waveform(data: out, buckets: buckets, channels: channels);
  }
}
