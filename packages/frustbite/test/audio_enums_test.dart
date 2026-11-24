import 'package:frustbite/frustbite.dart';
import 'package:frustbite/src/audio_enums.dart';
import 'package:test/test.dart';

void main() {
  test('every AudioContainer round-trips through the wire mapping', () {
    for (final v in AudioContainer.values) {
      expect(AudioContainerWire.fromWire(v.wireValue), v);
    }
  });

  test('every AudioCodec round-trips through the wire mapping', () {
    for (final v in AudioCodec.values) {
      expect(AudioCodecWire.fromWire(v.wireValue), v);
    }
  });

  test('every WaveformMode round-trips through the wire mapping', () {
    for (final v in WaveformMode.values) {
      expect(WaveformModeWire.fromWire(v.wireValue), v);
    }
  });

  test('FrustbiteException.toString uses the runtime type', () {
    expect(
      InvalidParameterException('x').toString(),
      startsWith('InvalidParameterException:'),
    );
  });
}
