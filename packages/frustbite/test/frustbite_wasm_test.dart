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

List<int> _uleb(int value) {
  final out = <int>[];
  do {
    var byte = value & 0x7F;
    value >>= 7;
    if (value != 0) byte |= 0x80;
    out.add(byte);
  } while (value != 0);
  return out;
}

List<int> _vec(List<List<int>> items) => [
  ..._uleb(items.length),
  for (final item in items) ...item,
];

List<int> _section(int id, List<int> content) => [
  id,
  ..._uleb(content.length),
  ...content,
];

List<int> _name(String name) {
  final bytes = utf8.encode(name);
  return [..._uleb(bytes.length), ...bytes];
}

const _i32 = 0x7F;

/// Assembles a module from `(export name, params, results, body)` functions;
/// the body excludes the locals vector and the final `end`.
Uint8List _module(
  List<(String, List<int>, List<int>, List<int>)> functions, {
  bool memory = false,
}) => Uint8List.fromList([
  ...[0, 0x61, 0x73, 0x6D, 1, 0, 0, 0], // magic, version
  ..._section(
    1,
    _vec([
      for (final (_, params, results, _) in functions)
        [
          0x60,
          ..._vec([
            for (final p in params) [p],
          ]),
          ..._vec([
            for (final r in results) [r],
          ]),
        ],
    ]),
  ),
  ..._section(3, _vec([for (var i = 0; i < functions.length; i++) _uleb(i)])),
  if (memory) ..._section(5, [1, 0, 1]), // one memory, min 1 page
  ..._section(
    7,
    _vec([
      for (final (i, (name, _, _, _)) in functions.indexed)
        [..._name(name), 0, ..._uleb(i)],
      if (memory) [..._name('memory'), 2, 0],
    ]),
  ),
  ..._section(
    10,
    _vec([
      // Each body is size-prefixed: no locals, the code, then `end`.
      for (final (_, _, _, body) in functions)
        [..._uleb(body.length + 2), 0, ...body, 0x0B],
    ]),
  ),
]);

/// A module whose only export is `frustbite_abi_version() => 3`.
Uint8List abiThreeModule() => _module([
  ('frustbite_abi_version', [], [_i32], [0x41, 3]),
]);

/// A fake engine with the current ABI that opens anything (handle 1234) and
/// traps (`unreachable`) in `frustbite_get_info`, like a Rust panic on wasm32.
Uint8List trappingModule() => _module([
  ('frustbite_abi_version', [], [_i32], [0x41, ..._sleb(frustbiteAbiVersion)]),
  ('frustbite_alloc', [_i32, _i32], [_i32], [0x41, 16]),
  ('frustbite_dealloc', [_i32, _i32, _i32], [], []),
  // *out = 1234; return Success.
  (
    'frustbite_open_memory',
    [_i32, _i32, _i32, _i32],
    [_i32],
    [0x20, 3, 0x41, ..._sleb(1234), 0x36, 2, 0, 0x41, 0],
  ),
  ('frustbite_free', [_i32], [], []),
  ('frustbite_get_info', [_i32, _i32], [_i32], [0x00]),
], memory: true);

List<int> _sleb(int value) {
  final out = <int>[];
  while (true) {
    final byte = value & 0x7F;
    value >>= 7;
    final done =
        (value == 0 && byte & 0x40 == 0) || (value == -1 && byte & 0x40 != 0);
    out.add(done ? byte : byte | 0x80);
    if (done) return out;
  }
}

/// A 16-bit stereo 44.1 kHz WAV of [seconds] seconds holding a square wave of
/// amplitude 0.25.
Uint8List squareWav(int seconds) {
  const rate = 44100, channels = 2;
  final frames = seconds * rate;
  final dataBytes = frames * channels * 2;
  final wav = ByteData(44 + dataBytes);
  void tag(int offset, String s) {
    for (var i = 0; i < 4; i++) {
      wav.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  wav.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  wav
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * channels * 2, Endian.little)
    ..setUint16(32, channels * 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  wav.setUint32(40, dataBytes, Endian.little);
  final samples = Int16List.view(wav.buffer, 44);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = (i ~/ 200).isEven ? 8192 : -8192;
  }
  return wav.buffer.asUint8List();
}

const _notInitialized =
    'Call Frustbite.initialize() before using frustbite on the web';

const _trapped =
    'frustbite wasm runtime trapped; reload the page or call '
    'Frustbite.initialize again';

Matcher _stateError(Object message) =>
    isA<StateError>().having((e) => e.message, 'message', message);

// The `loading` tests run first and in order: they need a page on which
// frustbite was never initialized. Every later group initializes on its own.
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
      'silence.flac',
    ]) {
      fixtures[name] = await fixture(name);
    }
  });

  group('loading', () {
    test('use before initialize throws StateError', () {
      expect(() => Frustbite.abiVersion, throwsA(_stateError(_notInitialized)));
      expect(
        () => Frustbite.fromMemory(fixtures['tone.mp3']!),
        throwsA(_stateError(_notInitialized)),
      );
      expect(
        () => Frustbite.fromFile('tone.mp3'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('initialize rejects bad arguments and bad modules', () async {
      await expectLater(
        Frustbite.initialize(
          wasmBytes: Uint8List(1),
          wasmUri: Uri.parse('frustbite.wasm'),
        ),
        throwsArgumentError,
      );
      await expectLater(
        Frustbite.initialize(wasmBytes: Uint8List(1)),
        throwsStateError,
      );
      // A valid module without the ABI export.
      await expectLater(
        Frustbite.initialize(wasmBytes: _module([])),
        throwsA(_stateError(contains('no usable ABI version'))),
      );
      await expectLater(
        Frustbite.initialize(wasmBytes: abiThreeModule()),
        throwsA(_stateError(contains('expected $frustbiteAbiVersion, got 3'))),
      );
      await expectLater(
        Frustbite.initialize(wasmUri: Uri.parse('missing.wasm')),
        throwsStateError,
      );
      expect(
        () => Frustbite.fromMemory(fixtures['tone.mp3']!),
        throwsA(_stateError(_notInitialized)),
      );
    });

    test(
      'a trap poisons the runtime until initialize loads a fresh one',
      () async {
        await Frustbite.initialize(wasmBytes: trappingModule());
        final first = Frustbite.fromMemory(Uint8List(16));
        final second = Frustbite.fromMemory(Uint8List(16));

        expect(
          () => first.info,
          throwsA(
            isA<UnknownFrustbiteException>()
                .having((e) => e.code, 'code', FrustbiteErrorCode.unknown)
                .having((e) => e.message, 'message', contains('trap')),
          ),
        );
        // Every later call, including open, is refused.
        expect(() => first.tags, throwsA(_stateError(_trapped)));
        expect(() => second.info, throwsA(_stateError(_trapped)));
        await expectLater(second.decodeAsync(), throwsA(_stateError(_trapped)));
        expect(() => Frustbite.abiVersion, throwsA(_stateError(_trapped)));
        expect(
          () => Frustbite.fromMemory(Uint8List(16)),
          throwsA(_stateError(_trapped)),
        );

        // initialize replaces the poisoned instance with a fresh one.
        await Frustbite.initialize();
        final fresh = Frustbite.fromMemory(fixtures['tone.mp3']!);
        expect(fresh.info.codec, AudioCodec.mp3);
        fresh.dispose();
        // Handles of the dead instance never reach the new one.
        expect(() => second.info, throwsA(_stateError(_trapped)));
        first.dispose();
        second.dispose();
        expect(first.isDisposed && second.isDisposed, isTrue);
      },
    );

    test(
      'concurrent initialize shares one load; a later call is a no-op',
      () async {
        await Future.wait([Frustbite.initialize(), Frustbite.initialize()]);
        await Frustbite.initialize(wasmBytes: Uint8List(1));
        expect(Frustbite.abiVersion, frustbiteAbiVersion);
      },
    );
  });

  group('initialized', () {
    // The default URI resolves `frustbite.wasm` next to the page.
    setUpAll(Frustbite.initialize);

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

    test('bulk copies: tone.wav decode', () {
      final audio = open('tone.wav');
      audio.decode(); // warm up
      final watch = Stopwatch()..start();
      const runs = 10;
      for (var i = 0; i < runs; i++) {
        expect(audio.decode().samples, hasLength(264600));
      }
      print(
        'tone.wav decode (264600 samples): '
        '${watch.elapsedMicroseconds / runs / 1000} ms per call',
      );
    });

    test('bulk copies: a 3-minute stereo WAV round trip', () {
      final wav = squareWav(180);
      var watch = Stopwatch()..start();
      final audio = Frustbite.fromMemory(wav);
      addTearDown(audio.dispose);
      final openMs = watch.elapsedMilliseconds;
      watch = Stopwatch()..start();
      final pcm = audio.decode();
      final decodeMs = watch.elapsedMilliseconds;
      print(
        '3-minute WAV: open (${wav.length} bytes in) $openMs ms, '
        'decode (${pcm.samples.length} floats out) $decodeMs ms',
      );
      expect(pcm.frames, 180 * 44100);
      expect(pcm.samples, hasLength(15876000));
      expect(pcm.samples[0], 0.25);
      expect(pcm.samples[200], -0.25);
      expect(pcm.samples[15875999], -0.25);
    });

    group('editing', () {
      test('render: trim, mono, resample, normalize', () {
        final tone = open('tone.wav');
        final out = tone
            .edit()
            .trim(end: const Duration(seconds: 1))
            .toMono()
            .resample(16000)
            .normalize(peakDb: -3)
            .render();
        addTearDown(out.dispose);
        expect(out.info.channels, 1);
        expect(out.info.sampleRate, 16000);
        expect((out.info.totalFrames - 16000).abs(), lessThanOrEqualTo(1));
        final peak = out.decode().samples.fold<double>(
          0,
          (max, x) => x.abs() > max ? x.abs() : max,
        );
        expect(peak, closeTo(0.7079, 1e-4));
        expect(tone.info.channels, 2);
      });

      test('concat with a crossfade and mix', () {
        final tone = open('tone.wav');
        final click = open('click.wav');
        final out = Frustbite.concat(
          [tone, tone],
          crossfade: const Duration(seconds: 1),
        ).mix(click, gainDb: -6).render();
        addTearDown(out.dispose);
        expect(out.info.totalFrames, 2 * 132300 - 44100);
      });

      test('toWav round trip and detectSilence', () async {
        final tone = open('tone.wav');
        final wav = Frustbite.fromMemory(tone.toWav());
        addTearDown(wav.dispose);
        expect(wav.decode().samples, tone.decode().samples);
        expect(await tone.toWavAsync(format: WavFormat.float32), isNotEmpty);
        final silence = open(
          'silence.flac',
        ).detectSilence(minDuration: const Duration(milliseconds: 100));
        expect(silence, hasLength(1));
        expect(silence.single.start, Duration.zero);
        expect(tone.detectSilence(), isEmpty);
      });

      test('saveWav is unsupported; bad parameters keep their type', () {
        final tone = open('tone.wav');
        expect(() => tone.saveWav('out.wav'), throwsUnsupportedError);
        expect(
          () => tone.edit().resample(0),
          throwsA(isA<InvalidParameterException>()),
        );
      });
    });

    test('many open and dispose cycles keep working', () {
      for (var i = 0; i < 200; i++) {
        final audio = Frustbite.fromMemory(fixtures['click.wav']!);
        expect(audio.info.sampleRate, 44100);
        audio.dispose();
      }
    });
  });
}
