import 'package:frustbite/frustbite.dart';
import 'package:frustbite/src/abi.dart';
import 'package:test/test.dart';

void main() {
  test('native ABI matches package', () {
    expect(Frustbite.abiVersion, frustbiteAbiVersion);
  });

  test('checkFrustbiteAbi throws on mismatch', () {
    expect(() => checkFrustbiteAbi(frustbiteAbiVersion + 1), throwsStateError);
    expect(() => checkFrustbiteAbi(frustbiteAbiVersion), returnsNormally);
  });
}
