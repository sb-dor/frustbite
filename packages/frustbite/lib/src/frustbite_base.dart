import 'abi.dart';
import 'bindings/bindings.dart' as bindings;

/// Entry point of the library.
abstract final class Frustbite {
  /// ABI version of the loaded native library, verified against this package.
  static int get abiVersion {
    final actual = bindings.frustbite_abi_version();
    checkFrustbiteAbi(actual);
    return actual;
  }
}
