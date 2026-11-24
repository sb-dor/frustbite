import 'package:frustbite/frustbite.dart';
import 'package:frustbite/src/audio_enums.dart';
import 'package:frustbite/src/enums.dart';
import 'package:frustbite/src/frustbite_exception.dart';
import 'package:test/test.dart';

void main() {
  test('every AudioContainer round-trips through the wire mapping', () {
    for (final v in AudioContainer.values) {
      expect(AudioContainerWire.fromWire(v.wireValue), v);
      expect(FrustbiteContainer.fromValue(v.wireValue).name, v.name);
    }
  });

  test('every AudioCodec round-trips through the wire mapping', () {
    for (final v in AudioCodec.values) {
      expect(AudioCodecWire.fromWire(v.wireValue), v);
      expect(FrustbiteCodec.fromValue(v.wireValue).name, v.name);
    }
  });

  test('every WaveformMode round-trips through the wire mapping', () {
    for (final v in WaveformMode.values) {
      expect(WaveformModeWire.fromWire(v.wireValue), v);
      expect(FrustbiteWaveformMode.fromValue(v.wireValue).name, v.name);
    }
  });

  test('FrustbiteException.toString uses the runtime type', () {
    expect(
      frustbiteError(FrustbiteErrorCode.invalidParameter, 'x').toString(),
      startsWith('InvalidParameterException:'),
    );
  });
}
