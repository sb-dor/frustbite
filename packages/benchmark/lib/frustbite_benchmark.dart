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

/// Like [_once], but opens [path] from disk (file I/O on both sides).
T _onceFile<T>(String path, T Function(Frustbite f) op) {
  final f = Frustbite.fromFile(path);
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
      () => _onceFile(inputs.mp3Path, (f) => (f.tags, f.cover)),
    ),
    // Editing. Each case decodes the WAV, runs the edit and encodes the result
    // as WAV bytes in one native call.
    'resample_wav_48k': bench(
      'resample_wav_48k',
      () => _once(
        inputs.wav,
        (f) => f.edit().resample(48000).toWav(format: WavFormat.float32),
      ),
    ),
    'resample_wav_16k_mono': bench(
      'resample_wav_16k_mono',
      () => _once(inputs.wav, (f) => f.edit().toMono().resample(16000).toWav()),
    ),
    'edit_wav': bench(
      'edit_wav',
      () => _once(
        inputs.wav,
        (f) => f
            .edit()
            .trim(
              start: const Duration(seconds: 10),
              end: const Duration(seconds: 170),
            )
            .fadeIn(const Duration(seconds: 2))
            .fadeOut(const Duration(seconds: 2))
            .normalize()
            .toWav(),
      ),
    ),
    'encode_wav': bench(
      'encode_wav',
      () => _once(inputs.wav, (f) => f.toWav()),
    ),
  };
}
