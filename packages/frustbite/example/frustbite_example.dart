import 'dart:io';

import 'package:frustbite/frustbite.dart';

/// Prints the codec info, tags and a 20-character ASCII waveform of a file.
///
/// ```sh
/// dart run example/frustbite_example.dart test/fixtures/tone.mp3
/// ```
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run example/frustbite_example.dart <audio file>',
    );
    exitCode = 64;
    return;
  }

  final Frustbite audio;
  try {
    audio = Frustbite.fromFile(args.first);
  } on FrustbiteException catch (e) {
    stderr.writeln('Cannot open ${args.first}: $e');
    exitCode = 1;
    return;
  }

  try {
    final info = audio.info;
    print('Container: ${info.container.name}, codec: ${info.codec.name}');
    print('${info.sampleRate} Hz, ${info.channels} channel(s)');
    print('Duration: ${info.duration}');

    final tags = audio.tags;
    print('Title: ${tags.title ?? '-'}');
    print('Artist: ${tags.artist ?? '-'}');
    print('Album: ${tags.album ?? '-'}');
    final cover = audio.cover;
    print('Cover: ${cover == null ? 'none' : cover.mimeType}');

    // 20 buckets in [0, 1], merged across channels, normalized to the loudest.
    final waveform = audio.waveform(buckets: 20).normalized();
    const levels = ' .:-=+*#%@';
    final line = StringBuffer();
    for (final value in waveform.channel(0)) {
      line.write(levels[(value * (levels.length - 1)).round()]);
    }
    print('Waveform: |$line|');
  } finally {
    audio.dispose();
  }
}
