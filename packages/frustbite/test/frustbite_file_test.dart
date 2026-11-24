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
