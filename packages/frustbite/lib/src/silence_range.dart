/// A silent stretch found by `Frustbite.detectSilence`: `[start, end)`.
final class SilenceRange {
  const SilenceRange(this.start, this.end);

  /// Where the silence starts.
  final Duration start;

  /// Where the sound comes back (exclusive); the end of the audio for
  /// trailing silence.
  final Duration end;

  /// Length of the silence.
  Duration get duration => end - start;

  @override
  bool operator ==(Object other) =>
      other is SilenceRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SilenceRange($start, $end)';
}

/// Pairs microsecond values (start, end, start, end, ...) into ranges.
List<SilenceRange> silenceRangesFromMicros(List<int> values) => [
  for (var i = 0; i + 1 < values.length; i += 2)
    SilenceRange(
      Duration(microseconds: values[i]),
      Duration(microseconds: values[i + 1]),
    ),
];
