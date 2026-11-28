import 'dart:math' as math;

import 'package:frustbite/frustbite.dart';
import 'package:material_ui/material_ui.dart';

/// Draws one mirrored bar per bucket, scaled so the loudest one fills the
/// height.
///
/// Bars outside [start]..[end] (fractions of the width) are dimmed, and
/// [handles] draws a grip at both ends of that range. [position] (a fraction)
/// draws the playback line.
class WaveformPainter extends CustomPainter {
  WaveformPainter(
    this.waveform,
    this.color, {
    this.start = 0,
    this.end = 1,
    this.handles = false,
    this.position,
  });

  final Waveform waveform;
  final Color color;
  final double start;
  final double end;
  final bool handles;
  final double? position;

  @override
  void paint(Canvas canvas, Size size) {
    if (waveform.channels == 0 || waveform.buckets == 0) return;
    final values = waveform.channel(0);
    if (values.isEmpty) return;
    final peak = values.reduce(math.max);
    final strokeWidth = math.max(1.0, size.width / values.length);
    final inside = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final outside = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    for (var i = 0; i < values.length; i++) {
      final t = (i + 0.5) / values.length;
      final x = t * size.width;
      final h = peak == 0 ? 0.0 : values[i] / peak * mid;
      final paint = t >= start && t <= end ? inside : outside;
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + math.max(h, 0.5)), paint);
    }
    if (handles) {
      final grip = Paint()
        ..color = color
        ..strokeWidth = 2;
      for (final t in [start, end]) {
        final x = t * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), grip);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, mid), width: 10, height: 28),
            const Radius.circular(5),
          ),
          grip,
        );
      }
    }
    final p = position;
    if (p != null) {
      final x = p.clamp(0.0, 1.0) * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.redAccent
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.waveform != waveform ||
      old.color != color ||
      old.start != start ||
      old.end != end ||
      old.handles != handles ||
      old.position != position;
}
