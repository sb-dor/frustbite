// AUTO GENERATED FILE, DO NOT EDIT.
//
// Generated from native/include/frustbite.h by tool/generate_bindings.dart.

enum FrustbiteErrorCode {
  /// The operation succeeded.
  success(0),
  /// The provided path is empty, malformed, or refers to a non-existent file.
  invalidPath(1),
  /// The audio format is not recognised or not supported by this build.
  unsupportedFormat(2),
  /// The audio bytes are corrupt or do not match the expected format.
  decodingError(3),
  /// An underlying I/O operation (read/write) failed.
  ioError(4),
  /// A handle or output pointer was null, or the handle has been freed.
  invalidPointer(5),
  /// A scalar parameter is out of range.
  invalidParameter(6),
  /// An unclassified error occurred.
  unknown(99);

  const FrustbiteErrorCode(this.value);

  final int value;

  static FrustbiteErrorCode fromValue(int value) =>
      values.firstWhere((e) => e.value == value, orElse: () => FrustbiteErrorCode.unknown);
}
