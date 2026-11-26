import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:frustbite/frustbite.dart';
import 'package:test/test.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

Frustbite open(String name) {
  final audio = Frustbite.fromMemory(fixture(name));
  addTearDown(audio.dispose);
  return audio;
}

/// Registers [audio] for disposal and returns it.
Frustbite owned(Frustbite audio) {
  addTearDown(audio.dispose);
  return audio;
}

double peak(Float32List samples) =>
    samples.fold(0.0, (max, x) => math.max(max, x.abs()));

void main() {
  test('trim keeps the range and leaves the source unchanged', () {
    final tone = open('tone.wav');
    final cut = owned(
      tone
          .edit()
          .trim(
            start: const Duration(milliseconds: 500),
            end: const Duration(seconds: 2),
          )
          .render(),
    );
    expect(cut.info.totalFrames, 66150);
    expect(cut.info.container, AudioContainer.wav);
    expect(tone.info.totalFrames, 132300);
    // A trim past the end is clamped.
    final empty = owned(
      tone.edit().trim(start: const Duration(seconds: 9)).render(),
    );
    expect(empty.info.totalFrames, 0);
    expect(empty.decode().samples, isEmpty);
  });

  test('toMono, resample and normalize compose in order', () {
    final tone = open('tone.wav');
    final out = owned(
      tone.edit().toMono().resample(16000).normalize(peakDb: -3).render(),
    );
    expect(out.info.channels, 1);
    expect(out.info.sampleRate, 16000);
    expect(out.info.totalFrames, closeTo(48000, 1));
    expect(peak(out.decode().samples), closeTo(0.7079, 1e-4));
    final stereo = owned(out.edit().toStereo().render());
    expect(stereo.info.channels, 2);
  });

  test('gain and fades', () {
    final tone = open('tone.wav');
    final quieter = owned(tone.edit().gain(-6.0206).render());
    expect(
      peak(quieter.decode().samples),
      closeTo(peak(tone.decode().samples) / 2, 1e-3),
    );
    final faded = owned(
      tone
          .edit()
          .fadeIn(const Duration(seconds: 1))
          .fadeOut(const Duration(seconds: 1))
          .render(),
    );
    final samples = faded.decode().samples;
    expect(samples[0], 0);
    expect(samples[samples.length - 1], 0);
  });

  test('concat with a crossfade overlaps the parts', () {
    final tone = open('tone.wav');
    final plain = owned(Frustbite.concat([tone, tone, tone]).render());
    expect(plain.info.totalFrames, 3 * 132300);
    final faded = owned(
      Frustbite.concat([
        tone,
        tone,
      ], crossfade: const Duration(seconds: 1)).render(),
    );
    expect(faded.info.totalFrames, 2 * 132300 - 44100);
    expect(() => Frustbite.concat([]), throwsArgumentError);
  });

  test('append conforms the rate and channel count of the other source', () {
    final mono = owned(
      open('tone.wav').edit().toMono().resample(8000).render(),
    );
    final out = owned(mono.edit().append(open('tone.wav')).render());
    expect(out.info.sampleRate, 8000);
    expect(out.info.channels, 1);
    expect(out.info.totalFrames, closeTo(2 * 24000, 1));
  });

  test('mix extends to the longer part', () {
    final tone = open('tone.wav');
    final click = open('click.wav');
    final out = owned(
      click
          .edit()
          .mix(tone, gainDb: -12, offset: const Duration(seconds: 1))
          .render(),
    );
    expect(out.info.totalFrames, closeTo(44100 + 132300, 1));
  });

  test('trimSilence and detectSilence find the quiet parts', () {
    final silence = open('silence.flac');
    final tone = open('tone.wav');
    final padded = owned(Frustbite.concat([silence, tone, silence]).render());
    final ranges = padded.detectSilence(
      minDuration: const Duration(milliseconds: 200),
    );
    expect(ranges, hasLength(2));
    expect(ranges.first.start, Duration.zero);
    expect(ranges.last.end, padded.info.duration);
    expect(
      ranges.first.duration,
      greaterThan(const Duration(milliseconds: 200)),
    );

    final trimmed = owned(padded.edit().trimSilence().render());
    expect(trimmed.info.totalFrames, closeTo(132300, 50));
    expect(tone.detectSilence(), isEmpty);
  });

  test('toWav pcm16 of a 16-bit WAV is lossless; every format reads back', () {
    final tone = open('tone.wav');
    final original = tone.decode().samples;
    for (final format in WavFormat.values) {
      final wav = owned(Frustbite.fromMemory(tone.toWav(format: format)));
      expect(wav.info.container, AudioContainer.wav, reason: '$format');
      expect(wav.decode().samples, original, reason: '$format');
    }
  });

  test('edit().toWav converts other formats', () {
    final bytes = open('tone.flac').edit().toMono().toWav();
    final wav = owned(Frustbite.fromMemory(bytes));
    expect(wav.info.channels, 1);
    expect(wav.info.bitsPerSample, 16);
  });

  test('saveWav writes a file that opens', () async {
    final dir = Directory.systemTemp.createTempSync('frustbite_edit_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tone = open('tone.wav');
    final path = '${dir.path}${Platform.pathSeparator}out.wav';
    tone.edit().trim(end: const Duration(seconds: 1)).saveWav(path);
    final saved = owned(Frustbite.fromFile(path));
    expect(saved.info.totalFrames, 44100);
    final asyncPath = '${dir.path}${Platform.pathSeparator}async.wav';
    await tone.saveWavAsync(asyncPath, format: WavFormat.float32);
    expect(owned(Frustbite.fromFile(asyncPath)).info.totalFrames, 132300);
    expect(
      () => tone.saveWav('${dir.path}${Platform.pathSeparator}no/such/dir.wav'),
      throwsA(isA<FrustbiteIoException>()),
    );
  });

  test('async forms match the sync ones', () async {
    final tone = open('tone.wav');
    final edit = tone.edit().toMono().trim(end: const Duration(seconds: 1));
    final rendered = owned(await edit.renderAsync());
    expect(rendered.info.totalFrames, 44100);
    expect(await edit.toWavAsync(), edit.toWav());
    expect(await open('silence.flac').detectSilenceAsync(), hasLength(1));
  });

  test('no source can be disposed while an async edit runs', () async {
    final tone = Frustbite.fromMemory(fixture('tone.wav'));
    final click = Frustbite.fromMemory(fixture('click.wav'));
    final future = tone.edit().append(click).renderAsync();
    expect(click.dispose, throwsStateError);
    expect(tone.dispose, throwsStateError);
    owned(await future);
    click.dispose();
    tone.dispose();
  });

  test('disposed sources are rejected', () {
    final tone = open('tone.wav');
    final click = Frustbite.fromMemory(fixture('click.wav'));
    final edit = tone.edit().append(click);
    click.dispose();
    expect(edit.render, throwsStateError);
    expect(() => tone.edit().mix(click), throwsStateError);
  });

  test('invalid arguments throw InvalidParameterException', () {
    final edit = open('tone.wav').edit();
    final invalid = throwsA(isA<InvalidParameterException>());
    expect(() => edit.trim(start: const Duration(seconds: -1)), invalid);
    expect(
      () => edit.trim(
        start: const Duration(seconds: 2),
        end: const Duration(seconds: 1),
      ),
      invalid,
    );
    expect(() => edit.gain(double.nan), invalid);
    expect(() => edit.normalize(peakDb: 1), invalid);
    expect(() => edit.fadeIn(const Duration(seconds: -1)), invalid);
    expect(() => edit.resample(0), invalid);
    expect(() => edit.resample(768001), invalid);
    expect(() => edit.trimSilence(thresholdDb: 3), invalid);
    expect(() => edit.mix(edit.render(), gainDb: double.infinity), invalid);
    expect(() => open('tone.wav').detectSilence(thresholdDb: 1), invalid);
    expect(
      () => open(
        'tone.wav',
      ).detectSilence(minDuration: const Duration(milliseconds: -1)),
      invalid,
    );
  });

  test('an edit is immutable', () {
    final base = open('tone.wav').edit();
    final mono = base.toMono();
    expect(base.length, 0);
    expect(mono.length, 1);
    expect(owned(base.render()).info.channels, 2);
    expect(owned(mono.render()).info.channels, 1);
  });
}
