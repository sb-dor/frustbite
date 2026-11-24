@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:frustbite/frustbite.dart';
import 'package:frustbite/src/abi.dart';
import 'package:test/test.dart';

// Build the module first: `dart tool/build_wasm.dart test/frustbite.wasm`.

@JS('fetch')
external JSPromise<_Response> _fetch(String url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// Fetches a fixture relative to the test page (`dart test` serves `test/`).
Future<Uint8List> fixture(String name) async {
  final response = await _fetch('fixtures/$name').toDart;
  if (!response.ok) {
    throw StateError('fixtures/$name: HTTP ${response.status}');
  }
  return (await response.arrayBuffer().toDart).toDart.asUint8List();
}

/// A minimal module whose only export is `frustbite_abi_version() => 3`.
Uint8List abiThreeModule() {
  final name = utf8.encode('frustbite_abi_version');
  return Uint8List.fromList([
    ...[0, 0x61, 0x73, 0x6D, 1, 0, 0, 0], // magic, version
    ...[1, 5, 1, 0x60, 0, 1, 0x7F], // type section: () -> i32
    ...[3, 2, 1, 0], // function section: one function of type 0
    ...[7, name.length + 4, 1, name.length, ...name, 0, 0], // export func 0
    ...[10, 6, 1, 4, 0, 0x41, 3, 0x0B], // code: i32.const 3
  ]);
}

const _notInitialized =
    'Call Frustbite.initialize() before using frustbite on the web';

void main() {
  final fixtures = <String, Uint8List>{};

  setUpAll(() async {
    for (final name in [
      'tone.mp3',
      'tone.opus',
      'tone.webm',
      'tone.wav',
      'tone_he.m4a',
      'corrupt.bin',
      'notags.wav',
      'click.wav',
    ]) {
      fixtures[name] = await fixture(name);
    }

    // Everything here runs before a successful initialize.
    final notInitialized = isA<StateError>().having(
      (e) => e.message,
      'message',
      _notInitialized,
    );
    expect(() => Frustbite.abiVersion, throwsA(notInitialized));
    expect(
      () => Frustbite.fromMemory(fixtures['tone.mp3']!),
      throwsA(notInitialized),
    );
    expect(
      () => Frustbite.fromFile('tone.mp3'),
      throwsA(isA<UnsupportedError>()),
    );

    await expectLater(
      Frustbite.initialize(
        wasmBytes: Uint8List(1),
        wasmUri: Uri.parse('frustbite.wasm'),
      ),
      throwsArgumentError,
    );
    await expectLater(
      Frustbite.initialize(wasmBytes: Uint8List(1)),
      throwsA(anything),
    );
    // A valid module without the ABI export.
    await expectLater(
      Frustbite.initialize(
        wasmBytes: Uint8List.fromList([0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('no usable ABI version'),
        ),
      ),
    );
    await expectLater(
      Frustbite.initialize(wasmBytes: abiThreeModule()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('expected $frustbiteAbiVersion, got 3'),
        ),
      ),
    );
    await expectLater(
      Frustbite.initialize(wasmUri: Uri.parse('missing.wasm')),
      throwsStateError,
    );
    expect(
      () => Frustbite.fromMemory(fixtures['tone.mp3']!),
      throwsA(notInitialized),
    );

    // The default URI resolves `frustbite.wasm` next to the page. Concurrent
    // calls share one load; a later call is a no-op.
    await Future.wait([Frustbite.initialize(), Frustbite.initialize()]);
    await Frustbite.initialize(wasmBytes: Uint8List(1));
  });

  Frustbite open(String name, {AudioContainer? format}) {
    final audio = Frustbite.fromMemory(fixtures[name]!, format: format);
    addTearDown(audio.dispose);
    return audio;
  }

  test('ABI matches package', () {
    expect(Frustbite.abiVersion, frustbiteAbiVersion);
  });

  test('fromFile throws UnsupportedError, even for an empty path', () {
    expect(
      () => Frustbite.fromFile('test/fixtures/tone.mp3'),
      throwsA(isA<UnsupportedError>()),
    );
    expect(() => Frustbite.fromFile(''), throwsA(isA<UnsupportedError>()));
  });

  group('tone.mp3', () {
    test('info', () {
      final info = open('tone.mp3').info;
      expect(info.container, AudioContainer.mp3);
      expect(info.codec, AudioCodec.mp3);
      expect(info.sampleRate, 44100);
      expect(info.channels, 2);
      expect(info.bitrate, greaterThan(0));
      expect(info.totalFrames, 132300);
      expect(
        (info.duration - const Duration(seconds: 3)).abs(),
        lessThan(const Duration(milliseconds: 50)),
      );
    });

    test('tags and cover', () {
      final audio = open('tone.mp3');
      expect(audio.tags.title, 'frustbite tone');
      expect(audio.tags.artist, 'frustbite');
      expect(audio.tags.album, 'fixtures');
      expect(audio.tags.genre, 'Test');
      expect(audio.tags.year, 2026);
      expect(audio.tags.track, 1);
      expect(audio.tags.trackTotal, 1);
      final cover = audio.cover!;
      expect(cover.mimeType, 'image/png');
      expect(cover.data.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('waveform', () {
      final audio = open('tone.mp3');
      final wave = audio.waveform();
      expect(wave.buckets, 100);
      expect(wave.channels, 1);
      expect(wave.data, hasLength(100));
      expect(wave.data.every((v) => v >= 0 && v <= 1), isTrue);
      expect(wave.data[50], greaterThan(0.4));
      final perChannel = audio.waveform(buckets: 64, perChannel: true);
      expect(perChannel.channels, 2);
      expect(perChannel.channel(1), hasLength(64));
    });

    test('decode', () {
      final pcm = open('tone.mp3').decode();
      expect(pcm.channels, 2);
      expect(pcm.sampleRate, 44100);
      expect(pcm.frames, 132300);
      expect(pcm.samples.every((s) => s.abs() <= 1), isTrue);
    });

    test('format hint', () {
      expect(
        open('tone.mp3', format: AudioContainer.mp3).info.codec,
        AudioCodec.mp3,
      );
    });
  });

  group('tone.opus', () {
    test('info', () {
      final info = open('tone.opus').info;
      expect(info.container, AudioContainer.ogg);
      expect(info.codec, AudioCodec.opus);
      expect(info.sampleRate, 48000);
      expect(info.channels, 2);
      expect(info.totalFrames, 144000);
      expect(info.duration, const Duration(seconds: 3));
    });

    test('tags and cover', () {
      final audio = open('tone.opus');
      expect(audio.tags.title, 'frustbite tone');
      expect(audio.tags.year, 2026);
      expect(audio.cover?.mimeType, 'image/png');
    });

    test('waveform', () {
      final wave = open('tone.opus').waveform(buckets: 128);
      expect(wave.data, hasLength(128));
      expect(wave.data.every((v) => v >= 0 && v <= 1), isTrue);
      expect(wave.data[32], greaterThan(0.4));
    });

    test('decode', () {
      final pcm = open('tone.opus').decode();
      expect(pcm.sampleRate, 48000);
      expect(pcm.channels, 2);
      expect(pcm.samples, hasLength(144000 * 2));
    });
  });

  group('tone.webm', () {
    test('info scans the duration the header lacks', () {
      final info = open('tone.webm').info;
      expect(info.container, AudioContainer.mkv);
      expect(info.codec, AudioCodec.opus);
      expect(info.sampleRate, 48000);
      expect(info.channels, 2);
      expect(
        (info.duration - const Duration(seconds: 3)).abs(),
        lessThan(const Duration(milliseconds: 50)),
      );
    });

    test('has no tags and no cover', () {
      final audio = open('tone.webm');
      expect(audio.tags.title, isNull);
      expect(audio.cover, isNull);
    });

    test('waveform covers the whole file', () {
      final wave = open('tone.webm').waveform();
      expect(wave.data, hasLength(100));
      expect(wave.data[99], greaterThan(0.4));
    });

    test('decode', () {
      final pcm = open('tone.webm').decode();
      expect(pcm.sampleRate, 48000);
      expect(pcm.channels, 2);
      expect((pcm.frames - 144000).abs(), lessThanOrEqualTo(960));
    });
  });

  test('tone.wav: a large decode survives memory growth', () {
    final audio = open('tone.wav');
    final wave = audio.waveform();
    expect(wave.data.every((v) => v >= 0.49 && v <= 0.51), isTrue);
    for (var i = 0; i < 3; i++) {
      final pcm = audio.decode();
      expect(pcm.frames, 132300);
      expect(pcm.samples[200].abs(), greaterThan(0));
    }
  });

  test('a file without tags gives empty tags and no cover', () {
    final audio = open('notags.wav');
    expect(audio.tags.title, isNull);
    expect(audio.tags.year, isNull);
    expect(audio.cover, isNull);
  });

  group('errors', () {
    test('HE-AAC throws UnsupportedFormatException', () {
      expect(
        () => Frustbite.fromMemory(fixtures['tone_he.m4a']!),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    test('corrupt bytes throw UnsupportedFormat or Decoding', () {
      expect(
        () => Frustbite.fromMemory(fixtures['corrupt.bin']!),
        throwsA(
          anyOf(isA<UnsupportedFormatException>(), isA<DecodingException>()),
        ),
      );
    });

    test('empty bytes throw DecodingException', () {
      expect(
        () => Frustbite.fromMemory(Uint8List(0)),
        throwsA(isA<DecodingException>()),
      );
    });

    test('waveform(buckets: 0) throws InvalidParameterException', () {
      expect(
        () => open('tone.mp3').waveform(buckets: 0),
        throwsA(isA<InvalidParameterException>()),
      );
    });
  });

  group('async', () {
    test('waveformAsync and decodeAsync equal the sync calls', () async {
      final audio = open('tone.opus');
      final wave = await audio.waveformAsync(buckets: 50, perChannel: true);
      expect(wave.data, audio.waveform(buckets: 50, perChannel: true).data);
      expect(wave.channels, 2);
      final pcm = await audio.decodeAsync();
      expect(pcm.samples, audio.decode().samples);
    });

    test('dispose while async is in flight throws StateError', () async {
      final audio = Frustbite.fromMemory(fixtures['tone.mp3']!);
      final future = audio.decodeAsync();
      expect(audio.dispose, throwsStateError);
      expect((await future).frames, 132300);
      audio.dispose();
      expect(audio.isDisposed, isTrue);
    });

    test('async errors keep their type', () async {
      final audio = open('tone.mp3');
      await expectLater(
        audio.waveformAsync(buckets: 0),
        throwsA(isA<InvalidParameterException>()),
      );
    });
  });

  test('use after dispose throws StateError; dispose twice is a no-op', () {
    final audio = Frustbite.fromMemory(fixtures['tone.mp3']!)..dispose();
    expect(() => audio.info, throwsStateError);
    expect(() => audio.tags, throwsStateError);
    expect(audio.decode, throwsStateError);
    expect(audio.dispose, returnsNormally);
  });

  test('many open and dispose cycles keep working', () {
    for (var i = 0; i < 200; i++) {
      final audio = Frustbite.fromMemory(fixtures['click.wav']!);
      expect(audio.info.sampleRate, 44100);
      audio.dispose();
    }
  });
}
