import 'dart:io';
import 'dart:typed_data';

import 'package:frustbite/frustbite.dart';
import 'package:test/test.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

void main() {
  late Frustbite audio;

  setUp(() => audio = Frustbite.fromMemory(fixture('tone.wav')));
  tearDown(() => audio.dispose());

  test('waveformAsync equals waveform', () async {
    final sync = audio.waveform(buckets: 50, perChannel: true);
    final async = await audio.waveformAsync(buckets: 50, perChannel: true);
    expect(async.data, sync.data);
    expect(async.buckets, sync.buckets);
    expect(async.channels, sync.channels);
  });

  test('decodeAsync equals decode', () async {
    final sync = audio.decode();
    final async = await audio.decodeAsync();
    expect(async.samples, sync.samples);
    expect(async.sampleRate, sync.sampleRate);
    expect(async.channels, sync.channels);
  });

  test('two concurrent async calls on one object both succeed', () async {
    final results = await Future.wait([
      audio.waveformAsync(buckets: 20),
      audio.decodeAsync(),
    ]);
    expect((results[0] as Waveform).data, hasLength(20));
    expect((results[1] as AudioPcm).samples, isNotEmpty);
  });

  test(
    'dispose during waveformAsync throws StateError and does not crash',
    () async {
      final future = audio.waveformAsync(buckets: 10);
      expect(
        audio.dispose,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Cannot dispose while an async operation is running',
          ),
        ),
      );
      expect((await future).data, hasLength(10));
      audio.dispose();
      expect(audio.isDisposed, isTrue);
    },
  );

  test('async on disposed object throws StateError', () async {
    audio.dispose();
    await expectLater(audio.waveformAsync(), throwsStateError);
    await expectLater(audio.decodeAsync(), throwsStateError);
  });

  Frustbite openThenDeleteFile() {
    final dir = Directory.systemTemp.createTempSync('frustbite_async_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/tone.wav')
      ..writeAsBytesSync(fixture('tone.wav'));
    final a = Frustbite.fromFile(file.path);
    addTearDown(a.dispose);
    file.deleteSync();
    return a;
  }

  test(
    'decodeAsync error from the isolate keeps its type and releases busy',
    () async {
      final a = openThenDeleteFile();
      await expectLater(a.decodeAsync(), throwsA(isA<InvalidPathException>()));
      expect(a.dispose, returnsNormally);
      expect(a.isDisposed, isTrue);
    },
  );

  test(
    'waveformAsync error from the isolate keeps its type and releases busy',
    () async {
      final a = openThenDeleteFile();
      await expectLater(
        a.waveformAsync(),
        throwsA(isA<InvalidPathException>()),
      );
      expect(a.dispose, returnsNormally);
      expect(a.isDisposed, isTrue);
    },
  );

  test('waveformAsync(buckets: 0) throws InvalidParameterException', () async {
    await expectLater(
      audio.waveformAsync(buckets: 0),
      throwsA(isA<InvalidParameterException>()),
    );
  });

  test('waveform(buckets: (1 << 32) + 1) throws InvalidParameterException', () {
    expect(
      () => audio.waveform(buckets: (1 << 32) + 1),
      throwsA(isA<InvalidParameterException>()),
    );
    expect(
      () => audio.waveform(buckets: 100001),
      throwsA(isA<InvalidParameterException>()),
    );
  });

  test('waveformAsync(buckets: (1 << 32) + 1) throws', () async {
    await expectLater(
      audio.waveformAsync(buckets: (1 << 32) + 1),
      throwsA(isA<InvalidParameterException>()),
    );
  });
}
