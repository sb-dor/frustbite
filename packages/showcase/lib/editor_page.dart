import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:frustbite/frustbite.dart';
import 'package:material_ui/material_ui.dart';

import 'playback.dart';
import 'waveform_painter.dart';

const _maxContentWidth = 720.0;
const _maxFade = Duration(seconds: 5);
const _sampleRates = [8000, 16000, 22050, 44100, 48000];

/// Formats [d] as m:ss.s.
String formatTime(Duration d) {
  final tenths = (d.inMilliseconds / 100).round();
  final minutes = tenths ~/ 600;
  final seconds = (tenths % 600) / 10;
  return '$minutes:${seconds.toStringAsFixed(1).padLeft(4, '0')}';
}

/// Edits [source] with frustbite's pipeline, plays the source and the result,
/// and saves the result as WAV. [source] stays owned by the caller.
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.name,
    required this.source,
    required this.waveform,
    required this.playback,
    required this.saveFile,
  });

  final String name;
  final Frustbite source;
  final Waveform waveform;
  final PlaybackFactory playback;
  final SaveFile saveFile;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

/// A rendered edit, with its waveform and (once played or saved) WAV bytes.
class _Result {
  _Result(this.audio, this.waveform);

  final Frustbite audio;
  final Waveform waveform;
  Uint8List? previewWav;
}

enum _Track { source, result }

class _EditorPageState extends State<EditorPage> {
  late final Playback _playback = widget.playback();
  final _subscriptions = <StreamSubscription<void>>[];

  // The trim range, as fractions of the source.
  double _start = 0;
  double _end = 1;
  bool _trimSilence = false;
  Duration _fadeIn = Duration.zero;
  Duration _fadeOut = Duration.zero;
  bool _mono = false;
  int? _sampleRate;
  bool _normalize = false;
  WavFormat _format = WavFormat.pcm16;

  _Result? _result;
  bool _stale = false;
  Uint8List? _sourceWav;

  _Track? _playing;
  Duration _position = Duration.zero;

  // Native work in flight; nothing the editor owns may be disposed meanwhile.
  bool _busy = false;
  bool _disposed = false;

  Duration get _total => widget.source.info.duration;
  Duration get _startTime => _total * _start;
  Duration get _endTime => _total * _end;
  Duration get _selection => _endTime - _startTime;
  Duration get _fadeLimit => _selection < _maxFade ? _selection : _maxFade;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        _playback.position.listen((p) {
          if (mounted) setState(() => _position = p);
        }),
      )
      ..add(
        _playback.completed.listen((_) {
          if (mounted) setState(() => _playing = null);
        }),
      );
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subscriptions) {
      s.cancel();
    }
    _playback.dispose();
    if (!_busy) _result?.audio.dispose();
    super.dispose();
  }

  /// Runs [body] with the controls disabled; errors go to a SnackBar.
  Future<void> _run(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      _showMessage(e is FrustbiteException ? e.message : '$e');
    } finally {
      _busy = false;
      if (_disposed) {
        _result?.audio.dispose();
      } else {
        setState(() {});
      }
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Marks the result as out of date after a control changed.
  void _changed(VoidCallback change) {
    setState(() {
      change();
      if (_fadeIn > _fadeLimit) _fadeIn = _fadeLimit;
      if (_fadeOut > _fadeLimit) _fadeOut = _fadeLimit;
      if (_result != null) _stale = true;
    });
  }

  AudioEdit _buildEdit() {
    var edit = widget.source.edit();
    if (_start > 0 || _end < 1) {
      edit = edit.trim(start: _startTime, end: _end < 1 ? _endTime : null);
    }
    if (_trimSilence) edit = edit.trimSilence();
    if (_fadeIn > Duration.zero) edit = edit.fadeIn(_fadeIn);
    if (_fadeOut > Duration.zero) edit = edit.fadeOut(_fadeOut);
    if (_mono) edit = edit.toMono();
    final rate = _sampleRate;
    if (rate != null) edit = edit.resample(rate);
    if (_normalize) edit = edit.normalize();
    return edit;
  }

  Future<void> _apply() => _run(() async {
    // One bucket per logical pixel of the result waveform.
    final width = math.min(MediaQuery.sizeOf(context).width - 64, _maxContentWidth);
    if (_playing == _Track.result) await _stop();
    final audio = await _buildEdit().renderAsync();
    final Waveform waveform;
    try {
      waveform = await audio.waveformAsync(buckets: math.max(1, width.round()));
    } catch (_) {
      audio.dispose();
      rethrow;
    }
    if (_disposed) {
      audio.dispose();
      return;
    }
    final previous = _result;
    setState(() {
      _result = _Result(audio, waveform);
      _stale = false;
    });
    previous?.audio.dispose();
  });

  Future<void> _stop() async {
    await _playback.stop();
    if (mounted) setState(() => _playing = null);
  }

  Future<void> _toggle(_Track track) async {
    if (_playing == track) return _stop();
    await _run(() async {
      final Uint8List bytes;
      if (track == _Track.source) {
        bytes = _sourceWav ??= await widget.source.toWavAsync();
      } else {
        final result = _result!;
        bytes = result.previewWav ??= await result.audio.toWavAsync();
      }
      if (_disposed) return;
      setState(() {
        _playing = track;
        _position = Duration.zero;
      });
      try {
        await _playback.playWav(bytes);
      } catch (_) {
        if (mounted) setState(() => _playing = null);
        rethrow;
      }
    });
  }

  Future<void> _save() => _run(() async {
    final bytes = await _result!.audio.toWavAsync(format: _format);
    final dot = widget.name.lastIndexOf('.');
    final base = dot > 0 ? widget.name.substring(0, dot) : widget.name;
    if (await widget.saveFile('$base-edited.wav', bytes)) {
      _showMessage('Saved $base-edited.wav');
    }
  });

  double? _positionFor(_Track track, Duration length) {
    if (_playing != track || length == Duration.zero) return null;
    return _position.inMicroseconds / length.inMicroseconds;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: Text('Edit ${widget.name}')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth + 32),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                _Section(
                  title: 'Source',
                  trailing: _PlayButton(
                    key: const ValueKey('play-source'),
                    playing: _playing == _Track.source,
                    onPressed: _busy && _playing != _Track.source
                        ? null
                        : () => _toggle(_Track.source),
                  ),
                  children: [
                    _TrimWaveform(
                      waveform: widget.waveform,
                      color: theme.colorScheme.primary,
                      start: _start,
                      end: _end,
                      position: _positionFor(_Track.source, _total),
                      onChanged: _busy
                          ? null
                          : (start, end) => _changed(() {
                              _start = start;
                              _end = end;
                            }),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Keep ${formatTime(_startTime)} to ${formatTime(_endTime)} '
                      '(${formatTime(_selection)} of ${formatTime(_total)})',
                      key: const ValueKey('selection'),
                    ),
                  ],
                ),
                _Section(
                  title: 'Edits',
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Trim silence'),
                      value: _trimSilence,
                      onChanged: _busy ? null : (v) => _changed(() => _trimSilence = v),
                    ),
                    _FadeSlider(
                      label: 'Fade in',
                      value: _fadeIn,
                      max: _fadeLimit,
                      onChanged: _busy ? null : (v) => _changed(() => _fadeIn = v),
                    ),
                    _FadeSlider(
                      label: 'Fade out',
                      value: _fadeOut,
                      max: _fadeLimit,
                      onChanged: _busy ? null : (v) => _changed(() => _fadeOut = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Mono'),
                      value: _mono,
                      onChanged: _busy ? null : (v) => _changed(() => _mono = v),
                    ),
                    Row(
                      children: [
                        const Expanded(child: Text('Sample rate')),
                        DropdownButton<int?>(
                          value: _sampleRate,
                          onChanged: _busy ? null : (v) => _changed(() => _sampleRate = v),
                          items: [
                            DropdownMenuItem(
                              child: Text('Original (${widget.source.info.sampleRate} Hz)'),
                            ),
                            for (final rate in _sampleRates)
                              DropdownMenuItem(value: rate, child: Text('$rate Hz')),
                          ],
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Normalize'),
                      subtitle: const Text('Peak at -1 dBFS'),
                      value: _normalize,
                      onChanged: _busy ? null : (v) => _changed(() => _normalize = v),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        key: const ValueKey('apply'),
                        onPressed: _busy || _selection == Duration.zero ? null : _apply,
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('Apply'),
                      ),
                    ),
                  ],
                ),
                if (result != null) _resultSection(theme, result),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _resultSection(ThemeData theme, _Result result) {
    final info = result.audio.info;
    return _Section(
      title: 'Result',
      trailing: _PlayButton(
        key: const ValueKey('play-result'),
        playing: _playing == _Track.result,
        onPressed: _busy && _playing != _Track.result ? null : () => _toggle(_Track.result),
      ),
      children: [
        SizedBox(
          height: 100,
          width: double.infinity,
          child: CustomPaint(
            key: const ValueKey('result-waveform'),
            painter: WaveformPainter(
              result.waveform,
              theme.colorScheme.primary,
              position: _positionFor(_Track.result, info.duration),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _Row('Duration', formatTime(info.duration), valueKey: const ValueKey('result-duration')),
        _Row('Sample rate', '${info.sampleRate} Hz'),
        _Row('Channels', '${info.channels}'),
        if (_stale)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'The edits changed. Apply them to update the result.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            DropdownButton<WavFormat>(
              value: _format,
              onChanged: _busy ? null : (v) => setState(() => _format = v!),
              items: const [
                DropdownMenuItem(value: WavFormat.pcm16, child: Text('16-bit')),
                DropdownMenuItem(value: WavFormat.pcm24, child: Text('24-bit')),
                DropdownMenuItem(value: WavFormat.float32, child: Text('32-bit float')),
              ],
            ),
            const Spacer(),
            FilledButton.tonalIcon(
              key: const ValueKey('save'),
              onPressed: _busy || _stale ? null : _save,
              icon: const Icon(Icons.save_alt),
              label: const Text('Save WAV'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ?trailing,
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({super.key, required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
    tooltip: playing ? 'Stop' : 'Play',
    onPressed: onPressed,
    icon: Icon(playing ? Icons.stop : Icons.play_arrow),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(child: Text(value, key: valueKey)),
      ],
    ),
  );
}

class _FadeSlider extends StatelessWidget {
  const _FadeSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final Duration value;
  final Duration max;
  final ValueChanged<Duration>? onChanged;

  @override
  Widget build(BuildContext context) {
    final maxSeconds = max.inMilliseconds / 1000;
    final onChanged = this.onChanged;
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label)),
        Expanded(
          child: Slider(
            value: math.min(value.inMilliseconds / 1000, maxSeconds),
            max: maxSeconds,
            divisions: maxSeconds >= 0.1 ? (maxSeconds * 10).round() : null,
            label: formatTime(value),
            onChanged: onChanged == null || maxSeconds == 0
                ? null
                : (v) => onChanged(Duration(milliseconds: (v * 1000).round())),
          ),
        ),
        SizedBox(width: 48, child: Text('${(value.inMilliseconds / 1000).toStringAsFixed(1)} s')),
      ],
    );
  }
}

/// The source waveform with draggable trim handles at both ends of the kept
/// range. A drag moves the handle nearest to where it started.
class _TrimWaveform extends StatefulWidget {
  const _TrimWaveform({
    required this.waveform,
    required this.color,
    required this.start,
    required this.end,
    required this.position,
    required this.onChanged,
  });

  final Waveform waveform;
  final Color color;
  final double start;
  final double end;
  final double? position;
  final void Function(double start, double end)? onChanged;

  @override
  State<_TrimWaveform> createState() => _TrimWaveformState();
}

class _TrimWaveformState extends State<_TrimWaveform> {
  bool _draggingStart = false;

  double _fraction(Offset local, double width) => (local.dx / width).clamp(0.0, 1.0);

  void _move(double t) {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    if (_draggingStart) {
      onChanged(math.min(t, widget.end), widget.end);
    } else {
      onChanged(widget.start, math.max(t, widget.start));
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      return GestureDetector(
        key: const ValueKey('trim'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) {
          final t = _fraction(d.localPosition, width);
          _draggingStart = (t - widget.start).abs() < (t - widget.end).abs();
          _move(t);
        },
        onHorizontalDragUpdate: (d) => _move(_fraction(d.localPosition, width)),
        child: SizedBox(
          height: 120,
          width: double.infinity,
          child: CustomPaint(
            painter: WaveformPainter(
              widget.waveform,
              widget.color,
              start: widget.start,
              end: widget.end,
              handles: true,
              position: widget.position,
            ),
          ),
        ),
      );
    },
  );
}
