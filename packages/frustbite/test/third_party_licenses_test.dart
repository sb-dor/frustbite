import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the package copy of THIRD_PARTY_LICENSES.md matches the repo root', () {
    final root = File('../../THIRD_PARTY_LICENSES.md');
    // Absent when the package is tested outside the repository.
    if (!root.existsSync()) return;
    final copy = File('THIRD_PARTY_LICENSES.md');
    expect(copy.existsSync(), isTrue);
    expect(
      copy.readAsStringSync(),
      root.readAsStringSync(),
      reason:
          'run: python3 -I native/tool/third_party_licenses.py (from the repo root)',
    );
  });
}
