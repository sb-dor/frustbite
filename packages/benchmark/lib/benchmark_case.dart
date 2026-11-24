import 'package:benchmark_harness/benchmark_harness.dart';

/// Keeps results reachable so the measured work cannot be optimised away.
Object? sink;

/// A benchmark whose [run] executes one operation once.
///
/// `benchmark_harness` provides the `BenchmarkBase` lifecycle
/// (`setup`/`run`/`teardown`); timing is done by [measureMedian] because the
/// harness's own `measure()` reports a mean over a fixed 2 s window, which is
/// far too few samples for operations that take seconds.
final class OpBenchmark extends BenchmarkBase {
  OpBenchmark(super.name, this._op);

  final Object? Function() _op;

  @override
  void run() => sink = _op();
}

/// Median wall-clock microseconds of [runs] executions of [bench], after
/// [warmup] untimed executions.
double measureMedian(BenchmarkBase bench, {int warmup = 2, int runs = 10}) {
  bench.setup();
  try {
    for (var i = 0; i < warmup; i++) {
      bench.run();
    }
    final samples = <int>[];
    final watch = Stopwatch();
    for (var i = 0; i < runs; i++) {
      watch
        ..reset()
        ..start();
      bench.run();
      watch.stop();
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    final mid = samples.length ~/ 2;
    return samples.length.isOdd
        ? samples[mid].toDouble()
        : (samples[mid - 1] + samples[mid]) / 2;
  } finally {
    bench.teardown();
  }
}
