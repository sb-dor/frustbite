import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showcase/main.dart';

/// Loads the sample [name] and waits (real time) until the waveform shows up.
Future<void> _loadSample(WidgetTester tester, String name) async {
  // Tall enough that the lazy ListView builds the waveform card too.
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const ShowcaseApp());
  await tester.tap(find.text(name));
  // Native FFI and the waveform isolate run outside the fake-async zone.
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (find.byKey(const ValueKey('waveform')).evaluate().isEmpty) {
    expect(DateTime.now().isBefore(deadline), isTrue, reason: 'waveform never appeared');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

void main() {
  testWidgets('shows info and waveform for bundled tone.mp3', (tester) async {
    await _loadSample(tester, 'tone.mp3');

    expect(find.text('mp3'), findsWidgets);
    expect(find.text('0:03'), findsOneWidget);
    expect(find.text('frustbite tone'), findsOneWidget);
    expect(find.byKey(const ValueKey('waveform')), findsOneWidget);
  });

  testWidgets('shows tags and 8 s duration for the demo sample', (tester) async {
    await _loadSample(tester, 'demo.mp3');

    expect(find.text('0:08'), findsOneWidget);
    expect(find.text('frustbite demo'), findsOneWidget);
  });
}
