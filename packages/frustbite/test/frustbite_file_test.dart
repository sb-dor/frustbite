import 'package:frustbite/frustbite.dart';
import 'package:test/test.dart';

void main() {
  test('fromFile reads info, tags and decodes', () {
    final audio = Frustbite.fromFile('test/fixtures/tone.mp3');
    addTearDown(audio.dispose);
    expect(audio.info.container, AudioContainer.mp3);
    expect(audio.info.sampleRate, 44100);
    expect(audio.tags.title, 'frustbite tone');
    expect(audio.cover?.mimeType, 'image/png');
    expect(audio.decode().channels, 2);
  });

  test('reads raw ADTS AAC', () {
    final audio = Frustbite.fromFile('test/fixtures/tone.aac');
    addTearDown(audio.dispose);
    final info = audio.info;
    expect(info.container, AudioContainer.adts);
    expect(info.codec, AudioCodec.aac);
    expect(info.sampleRate, 44100);
    expect(info.channels, 2);
    expect(
      (info.duration - const Duration(seconds: 3)).inMilliseconds.abs(),
      lessThan(50),
    );
    // Includes the 1024-frame encoder priming, like m4a.
    expect(audio.decode().frames, info.totalFrames);
  });

  test('fromFile honors the format hint', () {
    final audio = Frustbite.fromFile(
      'test/fixtures/tone.wav',
      format: AudioContainer.wav,
    );
    addTearDown(audio.dispose);
    expect(audio.info.codec, AudioCodec.pcm);
  });

  test('missing file throws InvalidPathException', () {
    expect(
      () => Frustbite.fromFile('test/fixtures/does_not_exist.wav'),
      throwsA(isA<InvalidPathException>()),
    );
  });

  test('empty path throws InvalidPathException', () {
    expect(() => Frustbite.fromFile(''), throwsA(isA<InvalidPathException>()));
  });
}
