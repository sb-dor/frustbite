import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:frustbite/frustbite.dart';
import 'package:material_ui/material_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required on web (loads web/frustbite.wasm), a no-op on native platforms.
  await Frustbite.initialize();
  runApp(const ShowcaseApp());
}

const _samples = ['demo.mp3', 'tone.mp3', 'tone.opus', 'tone.m4a'];
const _maxContentWidth = 720.0;

class ShowcaseApp extends StatelessWidget {
  const ShowcaseApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Frustbite showcase',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
    ),
    home: const ShowcasePage(),
  );
}

/// Everything shown for one loaded file.
class _Loaded {
  const _Loaded(this.name, this.audio, this.waveform);

  final String name;
  final Frustbite audio;
  final Waveform waveform;
}

class ShowcasePage extends StatefulWidget {
  const ShowcasePage({super.key});

  @override
  State<ShowcasePage> createState() => _ShowcasePageState();
}

class _ShowcasePageState extends State<ShowcasePage> {
  _Loaded? _loaded;
  String? _error;
  bool _loading = false;

  // Identifies the latest request, so a slower, older one is discarded.
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    _loaded?.audio.dispose();
    super.dispose();
  }

  Future<void> _openFile() => _load(() async {
    final file = await FilePicker.pickFile(type: FileType.audio);
    return file == null ? null : (file.name, await file.readAsBytes());
  });

  Future<void> _openSample(String name) => _load(() async {
    final data = await rootBundle.load('assets/$name');
    return (name, data.buffer.asUint8List());
  });

  /// Reads a source (null when cancelled), decodes it and shows the result.
  Future<void> _load(Future<(String, Uint8List)?> Function() read) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    // One bucket per logical pixel of the waveform.
    final width = math.min(MediaQuery.sizeOf(context).width - 32, _maxContentWidth);
    Frustbite? audio;
    try {
      final source = await read();
      if (source == null) return;
      audio = Frustbite.fromMemory(source.$2);
      final waveform = await audio.waveformAsync(buckets: width.round());
      if (generation != _generation || !mounted) {
        // Superseded while decoding: nothing is in flight anymore, so this is safe.
        audio.dispose();
        return;
      }
      final previous = _loaded;
      setState(() => _loaded = _Loaded(source.$1, audio!, waveform));
      previous?.audio.dispose();
    } catch (e) {
      audio?.dispose();
      if (generation == _generation && mounted) {
        setState(() => _error = e is FrustbiteException ? e.message : '$e');
      }
    } finally {
      if (generation == _generation && mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _loaded;
    return Scaffold(
      appBar: AppBar(title: const Text('Frustbite showcase')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth + 32),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _loading ? null : _openFile,
                      child: const Text('Open file'),
                    ),
                    for (final name in _samples)
                      OutlinedButton(
                        onPressed: _loading ? null : () => _openSample(name),
                        child: Text(name),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                if (loaded != null) ...[
                  _InfoCard(loaded.name, loaded.audio.info),
                  _TagsCard(loaded.audio.tags, loaded.audio.cover),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        height: 120,
                        width: double.infinity,
                        child: CustomPaint(
                          key: const ValueKey('waveform'),
                          painter: _WaveformPainter(
                            loaded.waveform,
                            Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final seconds = d.inSeconds % 60;
  return '${d.inMinutes}:${seconds.toString().padLeft(2, '0')}';
}

class _InfoCard extends StatelessWidget {
  const _InfoCard(this.name, this.info);

  final String name;
  final AudioInfo info;

  @override
  Widget build(BuildContext context) {
    final bitrate = info.bitrate;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _Row('Codec', info.codec.name),
            _Row('Container', info.container.name),
            _Row('Sample rate', '${info.sampleRate} Hz'),
            _Row('Channels', '${info.channels}'),
            _Row('Duration', _formatDuration(info.duration)),
            _Row('Bitrate', bitrate == null ? 'unknown' : '${(bitrate / 1000).round()} kbps'),
          ],
        ),
      ),
    );
  }
}

class _TagsCard extends StatelessWidget {
  const _TagsCard(this.tags, this.cover);

  final AudioTags tags;
  final AudioCover? cover;

  @override
  Widget build(BuildContext context) {
    final cover = this.cover;
    final entries = {
      'Title': tags.title,
      'Artist': tags.artist,
      'Album': tags.album,
      'Genre': tags.genre,
      'Year': tags.year?.toString(),
    }..removeWhere((_, value) => value == null);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cover != null)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Image.memory(
                  cover.data,
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 96,
                    height: 96,
                    child: Center(child: Icon(Icons.broken_image)),
                  ),
                ),
              ),
            Expanded(
              child: entries.isEmpty
                  ? const Text('No tags')
                  : Column(
                      children: [for (final e in entries.entries) _Row(e.key, e.value!)],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

/// Draws one mirrored bar per bucket, scaled so the loudest one fills the height.
class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.waveform, this.color);

  final Waveform waveform;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (waveform.channels == 0 || waveform.buckets == 0) return;
    final values = waveform.channel(0);
    if (values.isEmpty) return;
    final peak = values.reduce(math.max);
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(1, size.width / values.length)
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    for (var i = 0; i < values.length; i++) {
      final x = (i + 0.5) * size.width / values.length;
      final h = peak == 0 ? 0.0 : values[i] / peak * mid;
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + math.max(h, 0.5)), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.waveform != waveform || old.color != color;
}
