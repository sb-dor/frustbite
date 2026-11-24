/// Must match `frustbite_abi_version` in the Rust engine.
const frustbiteAbiVersion = 1;

/// Throws [StateError] when the loaded native library does not match this package.
void checkFrustbiteAbi(int actual) {
  if (actual != frustbiteAbiVersion) {
    throw StateError(
      'Frustbite ABI mismatch: expected $frustbiteAbiVersion, got $actual. '
      'Rebuild or download the binary matching this Frustbite package.',
    );
  }
}
