import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showcase/main.dart';

void main() {
  testWidgets('shows info and waveform for bundled tone.mp3', (tester) async {
    await tester.pumpWidget(const ShowcaseApp());

    await tester.tap(find.text('tone.mp3'));
    // Native FFI and the waveform isolate run outside the fake-async zone.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pumpAndSettle();

    expect(find.text('mp3'), findsWidgets);
    expect(find.text('0:03'), findsOneWidget);
    expect(find.byKey(const ValueKey('waveform')), findsOneWidget);
  });
}
