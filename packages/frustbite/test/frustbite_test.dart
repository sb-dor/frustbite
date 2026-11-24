import 'dart:io';
import 'dart:typed_data';

import 'package:frustbite/frustbite.dart';
import 'package:frustbite/src/abi.dart';
import 'package:test/test.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

void main() {
  test('native ABI matches package', () {
    expect(Frustbite.abiVersion, frustbiteAbiVersion);
  });

  test('checkFrustbiteAbi throws on mismatch', () {
    expect(() => checkFrustbiteAbi(frustbiteAbiVersion + 1), throwsStateError);
    expect(() => checkFrustbiteAbi(frustbiteAbiVersion), returnsNormally);
  });

  test('initialize is a no-op on native', () async {
    await Frustbite.initialize();
  });

  test('info of tone.wav', () {
    final audio = Frustbite.fromMemory(fixture('tone.wav'));
    addTearDown(audio.dispose);
    final info = audio.info;
    expect(info.container, AudioContainer.wav);
    expect(info.codec, AudioCodec.pcm);
    expect(info.sampleRate, 44100);
    expect(info.channels, 2);
    expect(info.bitsPerSample, 16);
    expect(info.totalFrames, 132300);
    expect(info.duration, const Duration(seconds: 3));
    expect(identical(audio.info, info), isTrue);
  });

  test('tags of tone.mp3', () {
    final audio = Frustbite.fromMemory(fixture('tone.mp3'));
    addTearDown(audio.dispose);
    expect(audio.tags.title, 'frustbite tone');
    expect(audio.tags.year, 2026);
  });

  test('tags of a file without tags are empty', () {
    final audio = Frustbite.fromMemory(fixture('notags.wav'));
    addTearDown(audio.dispose);
    expect(audio.tags.title, isNull);
    expect(audio.cover, isNull);
  });

  test('cover of tone.mp3 is png', () {
    final audio = Frustbite.fromMemory(fixture('tone.mp3'));
    addTearDown(audio.dispose);
    final cover = audio.cover!;
    expect(cover.mimeType, 'image/png');
    expect(cover.data.sublist(1, 4), [0x50, 0x4E, 0x47]);
  });

  test('waveform defaults to 100 merged peak buckets in [0.49, 0.51] '
      'for tone.wav', () {
    final audio = Frustbite.fromMemory(fixture('tone.wav'));
    addTearDown(audio.dispose);
    final wave = audio.waveform();
    expect(wave.buckets, 100);
    expect(wave.channels, 1);
    expect(wave.data, hasLength(100));
    expect(wave.data.every((v) => v >= 0.49 && v <= 0.51), isTrue);
  });

  test('per-channel waveform is channel-major and normalizes', () {
    final audio = Frustbite.fromMemory(fixture('tone.wav'));
    addTearDown(audio.dispose);
    final wave = audio.waveform(buckets: 10, perChannel: true);
    expect(wave.channels, 2);
    expect(wave.data, hasLength(20));
    expect(wave.channel(1), hasLength(10));
    expect(() => wave.channel(2), throwsRangeError);
    expect(wave.normalized().data.reduce((a, b) => a > b ? a : b), 1.0);
    final zero = Waveform(data: Float32List(4), buckets: 4, channels: 1);
    expect(zero.normalized().data, everyElement(0));
  });

  test('decode tone.flac gives 132300 frames, 2 channels, 44100 Hz', () {
    final audio = Frustbite.fromMemory(fixture('tone.flac'));
    addTearDown(audio.dispose);
    final pcm = audio.decode();
    expect(pcm.frames, 132300);
    expect(pcm.channels, 2);
    expect(pcm.sampleRate, 44100);
    expect(pcm.duration, const Duration(seconds: 3));
  });

  test('HE-AAC throws UnsupportedFormatException', () {
    expect(
      () => Frustbite.fromMemory(fixture('tone_he.m4a')),
      throwsA(isA<UnsupportedFormatException>()),
    );
    try {
      Frustbite.fromMemory(fixture('tone_he.m4a'));
    } on FrustbiteException catch (e) {
      expect(e.code, FrustbiteErrorCode.unsupportedFormat);
    }
  });

  test(
    'corrupt bytes throw UnsupportedFormatException or DecodingException',
    () {
      expect(
        () => Frustbite.fromMemory(fixture('corrupt.bin')),
        throwsA(
          anyOf(isA<UnsupportedFormatException>(), isA<DecodingException>()),
        ),
      );
    },
  );

  test('empty bytes throw DecodingException', () {
    expect(
      () => Frustbite.fromMemory(Uint8List(0)),
      throwsA(isA<DecodingException>()),
    );
  });

  test('waveform(buckets: 0) throws InvalidParameterException', () {
    final audio = Frustbite.fromMemory(fixture('tone.wav'));
    addTearDown(audio.dispose);
    expect(
      () => audio.waveform(buckets: 0),
      throwsA(isA<InvalidParameterException>()),
    );
  });

  test('use after dispose throws StateError', () {
    final audio = Frustbite.fromMemory(fixture('tone.wav'))..dispose();
    expect(audio.isDisposed, isTrue);
    expect(() => audio.info, throwsStateError);
    expect(() => audio.tags, throwsStateError);
    expect(() => audio.cover, throwsStateError);
    expect(audio.waveform, throwsStateError);
    expect(audio.decode, throwsStateError);
  });

  test('dispose twice is a no-op', () {
    final audio = Frustbite.fromMemory(fixture('tone.wav'))..dispose();
    expect(audio.dispose, returnsNormally);
  });
}
