import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:showcase/main.dart';
import 'package:showcase/playback.dart';

class _FakePlayback implements Playback {
  final played = <Uint8List>[];
  final _position = StreamController<Duration>.broadcast();
  final _completed = StreamController<void>.broadcast();

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Future<void> playWav(Uint8List bytes) async => played.add(bytes);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _position.close();
    await _completed.close();
  }
}

/// Pumps (real time) until [finder] finds something.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  // Native FFI and the background isolates run outside the fake-async zone.
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (finder.evaluate().isEmpty) {
    expect(DateTime.now().isBefore(deadline), isTrue, reason: '$finder never appeared');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

/// Opens demo.mp3 (8 s) in the editor.
Future<void> _openEditor(
  WidgetTester tester, {
  Playback? playback,
  SaveFile? saveFile,
}) async {
  // Tall enough that the lazy ListViews build every card.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ShowcaseApp(
      playback: () => playback ?? _FakePlayback(),
      saveFile: saveFile ?? (_, _) async => false,
    ),
  );
  await tester.tap(find.text('demo.mp3'));
  await _waitFor(tester, find.byKey(const ValueKey('edit')));
  await tester.tap(find.byKey(const ValueKey('edit')));
  await tester.pumpAndSettle();
}

Future<void> _applyAndWait(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('apply')));
  await tester.pump();
  await _waitFor(tester, find.byKey(const ValueKey('result-waveform')));
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  testWidgets('applies the edits to the whole file by default', (tester) async {
    await _openEditor(tester);
    expect(_text(tester, 'selection'), 'Keep 0:00.0 to 0:08.0 (0:08.0 of 0:08.0)');

    await _applyAndWait(tester);

    expect(_text(tester, 'result-duration'), '0:08.0');
  });

  testWidgets('dragging the end handle trims the result', (tester) async {
    await _openEditor(tester);
    final trim = tester.getRect(find.byKey(const ValueKey('trim')));
    await tester.dragFrom(
      Offset(trim.right - 1, trim.center.dy),
      Offset(-trim.width / 2, 0),
    );
    await tester.pump();

    final selection = _text(tester, 'selection');
    expect(selection, startsWith('Keep 0:00.0 to 0:04'));

    await _applyAndWait(tester);

    expect(_text(tester, 'result-duration'), startsWith('0:04'));
  });

  testWidgets('saves the result as WAV bytes named after the source', (tester) async {
    String? savedName;
    Uint8List? savedBytes;
    await _openEditor(
      tester,
      saveFile: (name, bytes) async {
        savedName = name;
        savedBytes = bytes;
        return true;
      },
    );
    await _applyAndWait(tester);

    await tester.tap(find.byKey(const ValueKey('save')));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (savedBytes == null) {
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'never saved');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(savedName, 'demo-edited.wav');
    expect(ascii.decode(savedBytes!.sublist(0, 4)), 'RIFF');
  });

  testWidgets('plays the source as WAV', (tester) async {
    final playback = _FakePlayback();
    await _openEditor(tester, playback: playback);

    await tester.tap(find.byKey(const ValueKey('play-source')));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (playback.played.isEmpty) {
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'never played');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(ascii.decode(playback.played.single.sublist(0, 4)), 'RIFF');
  });
}
