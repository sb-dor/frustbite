import 'dart:io';
import 'dart:typed_data';

import 'package:audio_decode/audio_decode.dart' as ad;
import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:glint_audio_pure/glint_audio_pure.dart' as glint;
import 'package:wav/wav.dart' as wav;

import 'benchmark_case.dart';
import 'inputs.dart';

/// JSON key and display name of every baseline package.
const baselineLabels = {
  'audio_decode': 'audio_decode (C via FFI)',
  'glint_audio_pure': 'glint_audio_pure (pure Dart)',
  'wav': 'wav (pure Dart)',
  'audio_metadata_reader': 'audio_metadata_reader (pure Dart)',
};

/// Same peak-per-bucket algorithm as frustbite's merged waveform: bucket `b`
/// covers frames `[b*n/buckets, (b+1)*n/buckets)`, and every channel of those
/// frames contributes to one value, the largest absolute sample in [0, 1].
Float32List peakBuckets(Int16List samples, int channels, int buckets) {
  final frames = samples.length ~/ channels;
  final out = Float32List(buckets);
  for (var b = 0; b < buckets; b++) {
    final lo = b * frames ~/ buckets;
    final hi = (b + 1) * frames ~/ buckets;
    var peak = 0;
    for (var i = lo * channels; i < hi * channels; i++) {
      final v = samples[i];
      final a = v < 0 ? -v : v;
      if (a > peak) peak = a;
    }
    out[b] = (peak / 32768.0).clamp(0.0, 1.0);
  }
  return out;
}

/// Baseline cases: `case key -> {baseline key -> benchmark}`.
///
/// What each baseline returns is documented in the README. Where a baseline
/// yields int16 samples, conversion to f32 (`toFloat32()`) is included in the
/// measured work so every contender delivers float samples.
Map<String, Map<String, BenchmarkBase>> baselineCases(Inputs inputs) {
  OpBenchmark bench(String baseline, String key, Object? Function() op) =>
      OpBenchmark('$baseline $key', op);

  return {
    'decode_mp3': {
      'audio_decode': bench(
        'audio_decode',
        'decode_mp3',
        () => ad.decodeMp3(inputs.mp3).toFloat32(),
      ),
      'glint_audio_pure': bench(
        'glint_audio_pure',
        'decode_mp3',
        () => glint.mp3Decode(inputs.mp3), // Float64List, interleaved
      ),
    },
    'decode_vorbis': {
      'audio_decode': bench(
        'audio_decode',
        'decode_vorbis',
        () => ad.decodeOgg(inputs.ogg).toFloat32(),
      ),
    },
    'decode_wav': {
      'wav': bench(
        'wav',
        'decode_wav',
        () => wav.Wav.read(inputs.wav), // List<Float64List>, per channel
      ),
      'audio_decode': bench(
        'audio_decode',
        'decode_wav',
        () => ad.decodeWav(inputs.wav).toFloat32(),
      ),
    },
    'waveform_mp3_1000': {
      'audio_decode': bench('audio_decode', 'waveform_mp3_1000', () {
        final pcm = ad.decodeMp3(inputs.mp3);
        return peakBuckets(pcm.samples, pcm.channels, 1000);
      }),
    },
    'tags_mp3': {
      // Only accepts a File: reads from disk (OS page cache is warm).
      'audio_metadata_reader': bench(
        'audio_metadata_reader',
        'tags_mp3',
        () => amr.readMetadata(File(inputs.mp3Path), getImage: true),
      ),
    },
  };
}
