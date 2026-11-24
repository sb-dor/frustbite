import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:frustbite/frustbite.dart';

import 'benchmark_case.dart';
import 'inputs.dart';

/// Opens a fresh [Frustbite] on [source], runs [op] and disposes it, so
/// lazily cached `info`/`tags` never make a repeat run free.
T _once<T>(Uint8List source, T Function(Frustbite f) op) {
  final f = Frustbite.fromMemory(source);
  try {
    return op(f);
  } finally {
    f.dispose();
  }
}

/// Every frustbite case, keyed by case name. Sources are preloaded bytes.
Map<String, BenchmarkBase> frustbiteCases(Inputs inputs) {
  OpBenchmark bench(String key, Object? Function() op) =>
      OpBenchmark('frustbite $key', op);

  return {
    'info_mp3': bench('info_mp3', () => _once(inputs.mp3, (f) => f.info)),
    'decode_mp3': bench(
      'decode_mp3',
      () => _once(inputs.mp3, (f) => f.decode()),
    ),
    'decode_vorbis': bench(
      'decode_vorbis',
      () => _once(inputs.ogg, (f) => f.decode()),
    ),
    'decode_flac': bench(
      'decode_flac',
      () => _once(inputs.flac, (f) => f.decode()),
    ),
    'decode_wav': bench(
      'decode_wav',
      () => _once(inputs.wav, (f) => f.decode()),
    ),
    'waveform_mp3_1000': bench(
      'waveform_mp3_1000',
      () => _once(inputs.mp3, (f) => f.waveform(buckets: 1000)),
    ),
    'tags_mp3': bench(
      'tags_mp3',
      () => _once(inputs.mp3, (f) => (f.tags, f.cover)),
    ),
  };
}
