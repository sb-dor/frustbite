import 'dart:convert';
import 'dart:io';

import 'package:frustbite_benchmark/baseline_benchmark.dart';
import 'package:frustbite_benchmark/benchmark_case.dart';
import 'package:frustbite_benchmark/frustbite_benchmark.dart';
import 'package:frustbite_benchmark/inputs.dart';

const _runs = 10;
const _warmup = 2;

String _machine() {
  try {
    final brand = Process.runSync('sysctl', ['-n', 'machdep.cpu.brand_string']);
    if (brand.exitCode == 0) {
      return '${(brand.stdout as String).trim()}, '
          '${Platform.numberOfProcessors} cores';
    }
  } on ProcessException {
    // Not macOS: fall through.
  }
  return '${Platform.operatingSystem}, ${Platform.numberOfProcessors} cores';
}

String _fmtMs(double? us) =>
    us == null ? '—' : (us / 1000).toStringAsFixed(2).padLeft(10);

void main(List<String> args) {
  final quick = args.contains('--quick');
  final runs = quick ? 1 : _runs;
  final warmup = quick ? 0 : _warmup;

  final inputs = Inputs.load();
  final ours = frustbiteCases(inputs);
  final theirs = baselineCases(inputs);

  print(
    'Median milliseconds per operation '
    '(${quick ? 'quick: 1 run, no warm-up' : '$_runs runs after $_warmup warm-up runs'})\n',
  );
  const names = [
    'audio_decode',
    'glint_audio_pure',
    'wav',
    'audio_metadata_reader',
  ];
  print(
    '${'operation'.padRight(20)}${'frustbite'.padLeft(10)}'
    '${names.map((n) => n.padLeft(23)).join()}',
  );

  final results = <String, Map<String, double>>{};
  for (final MapEntry(key: key, value: bench) in ours.entries) {
    final row = <String, double>{
      'frustbite_us': measureMedian(bench, warmup: warmup, runs: runs),
    };
    for (final MapEntry(key: baseline, value: b)
        in (theirs[key] ?? const {}).entries) {
      row['${baseline}_us'] = measureMedian(b, warmup: warmup, runs: runs);
    }
    results[key] = row;
    print(
      '${key.padRight(20)}${_fmtMs(row['frustbite_us'])}'
      '${names.map((n) => _fmtMs(row['${n}_us']).padLeft(23)).join()}',
    );
  }

  if (quick) {
    print('\nQuick mode: results not saved.');
    return;
  }
  final file = File('benchmark_results.json');
  final json = const JsonEncoder.withIndent('  ').convert({
    'timestamp': DateTime.now().toIso8601String(),
    'machine': _machine(),
    'dart': Platform.version.split(' ').first,
    'results': results,
  });
  file.writeAsStringSync(json);
  print('\nResults saved to: ${file.absolute.path}');

  // chart.html embeds the JSON (no fetch), so it renders from file:// too.
  final chart = File('chart.html');
  if (chart.existsSync()) {
    final html = chart.readAsStringSync();
    final pattern = RegExp(
      r'(<script id="data" type="application/json">)[\s\S]*?(</script>)',
    );
    chart.writeAsStringSync(
      html.replaceFirstMapped(pattern, (m) => '${m[1]}\n$json\n${m[2]}'),
    );
    print('Embedded results in: ${chart.absolute.path}');
  }
}
