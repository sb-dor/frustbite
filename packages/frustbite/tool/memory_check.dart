import 'dart:async';
import 'dart:io';

import 'package:frustbite/frustbite.dart';

/// Acceptance check: a waveform of a 1-hour file must stay within
/// [maxDeltaMb] of resident memory above the baseline (streaming, bounded).
///
/// ```sh
/// dart run tool/memory_check.dart
/// ```
///
/// `ProcessInfo.maxRss` is a process-lifetime high-water mark that cannot be
/// reset (and already includes `dart run` start-up), so each child instead
/// samples `currentRss` during the run. The parent generates the mp3 once
/// (with ffmpeg, in its own process) and then measures each mode in a fresh
/// child process, re-invoking this script with `--mode=<name>`. Exits 1 if any mode exceeds the
/// threshold or a child reports no result, 2 if ffmpeg is unavailable.
const maxDeltaMb = 50.0;
const _mb = 1024 * 1024;

/// Name -> (perChannel, mode) for each measured configuration.
const _modes = <String, (bool, WaveformMode)>{
  'peak': (false, WaveformMode.peak),
  'per-channel': (true, WaveformMode.peak),
  'rms': (false, WaveformMode.rms),
};

Future<void> main(List<String> args) async {
  final child = args.where((a) => a.startsWith('--mode=')).firstOrNull;
  if (child != null) {
    exit(await _measure(child.substring(7), args.last));
  }
  exit(await _runAll());
}

Future<ProcessResult> _ffmpeg(String path) => Process.run('ffmpeg', [
  '-v',
  'error',
  '-y',
  '-f',
  'lavfi',
  '-i',
  'sine=frequency=440:sample_rate=44100:duration=3600',
  '-f',
  'lavfi',
  '-i',
  'anoisesrc=color=pink:amplitude=0.1:sample_rate=44100:duration=3600',
  '-filter_complex',
  '[0][1]amix=inputs=2:duration=first,aformat=channel_layouts=stereo',
  '-ar',
  '44100',
  '-ac',
  '2',
  '-c:a',
  'libmp3lame',
  '-b:a',
  '64k',
  path,
]);

Future<int> _runAll() async {
  final dir = Directory.systemTemp.createTempSync('frustbite_mem_');
  try {
    final path = '${dir.path}/hour.mp3';
    stdout.writeln('Generating 1-hour 44.1 kHz stereo 64 kbps mp3 ...');
    final ProcessResult gen;
    try {
      gen = await _ffmpeg(path);
    } on ProcessException {
      stderr.writeln(
        'ffmpeg not found on PATH; install it (e.g. brew install ffmpeg)',
      );
      return 2;
    }
    if (gen.exitCode != 0) {
      stderr.writeln('ffmpeg failed: ${gen.stderr}');
      return 2;
    }
    var failed = false;
    for (final mode in _modes.keys) {
      final r = await Process.run(Platform.resolvedExecutable, [
        'run',
        Platform.script.toFilePath(),
        '--mode=$mode',
        path,
      ]);
      stdout.write(r.stdout);
      stderr.write(r.stderr);
      // A child that exits 0 without reporting must not pass.
      final reported = RegExp(
        '^RESULT mode=$mode delta_mb=[0-9.]+\$',
        multiLine: true,
      ).hasMatch('${r.stdout}');
      if (r.exitCode != 0 || !reported) {
        if (!reported) stderr.writeln('[$mode] no RESULT line from child');
        failed = true;
      }
    }
    stdout.writeln(
      failed
          ? 'FAIL: memory check exceeded ${maxDeltaMb.toStringAsFixed(0)} MB'
          : 'PASS: all modes within ${maxDeltaMb.toStringAsFixed(0)} MB',
    );
    return failed ? 1 : 0;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

Future<int> _measure(String name, String path) async {
  final (perChannel, mode) = _modes[name]!;
  // Load the native library first so its mapping is part of the baseline.
  Frustbite.abiVersion;
  final baseline = ProcessInfo.currentRss;
  final audio = Frustbite.fromFile(path);
  // maxRss is a lifetime high-water mark and `dart run` start-up (compile)
  // already pushes it ~70 MB above the steady state, so it cannot be used for
  // a delta. Instead sample currentRss while the waveform runs on a worker
  // isolate (the sync call would block this isolate's sampler).
  var peak = baseline;
  final sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > peak) peak = rss;
  });
  try {
    final info = audio.info;
    final sw = Stopwatch()..start();
    await audio.waveformAsync(
      buckets: 1000,
      mode: mode,
      perChannel: perChannel,
    );
    sw.stop();
    sampler.cancel();
    final end = ProcessInfo.currentRss;
    if (end > peak) peak = end;
    final delta = (peak - baseline) / _mb;
    final ok = delta <= maxDeltaMb;
    stdout.writeln(
      '[$name] file ${(File(path).lengthSync() / _mb).toStringAsFixed(1)} MB, '
      'duration ${info.duration}, waveform ${sw.elapsedMilliseconds} ms\n'
      '[$name] baseline ${(baseline / _mb).toStringAsFixed(1)} MB, '
      'peak ${(peak / _mb).toStringAsFixed(1)} MB, '
      'delta ${delta.toStringAsFixed(1)} MB '
      '(limit ${maxDeltaMb.toStringAsFixed(0)} MB) ${ok ? 'OK' : 'FAIL'}',
    );
    stdout.writeln('RESULT mode=$name delta_mb=${delta.toStringAsFixed(1)}');
    return ok ? 0 : 1;
  } finally {
    sampler.cancel();
    audio.dispose();
  }
}
