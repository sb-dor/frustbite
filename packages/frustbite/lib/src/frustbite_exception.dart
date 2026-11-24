import 'enums.dart';

/// Base class of every error reported by the Frustbite engine.
sealed class FrustbiteException implements Exception {
  FrustbiteException._(this.code, String? context)
    : message = context == null || context.isEmpty
          ? _defaultMessage(code)
          : '${_defaultMessage(code)} ($context)';

  /// The native error code behind this exception.
  final FrustbiteErrorCode code;

  /// Human-readable description.
  final String message;

  @override
  String toString() => '$runtimeType: $message (code: ${code.name})';

  static String _defaultMessage(FrustbiteErrorCode code) => switch (code) {
    FrustbiteErrorCode.success => 'Success',
    FrustbiteErrorCode.invalidPath => 'Invalid or missing path',
    FrustbiteErrorCode.unsupportedFormat =>
      'Unsupported audio format, or format not enabled in this build',
    FrustbiteErrorCode.decodingError => 'Failed to decode audio',
    FrustbiteErrorCode.ioError => 'I/O error occurred',
    FrustbiteErrorCode.invalidPointer =>
      'Invalid pointer (audio may have been disposed)',
    FrustbiteErrorCode.invalidParameter => 'Invalid parameter',
    FrustbiteErrorCode.unknown => 'An unknown error occurred',
  };
}

/// The audio format is not recognised or not enabled in this build.
final class UnsupportedFormatException extends FrustbiteException {
  UnsupportedFormatException([String? context])
    : super._(FrustbiteErrorCode.unsupportedFormat, context);
}

/// The audio data is corrupt or does not match the expected format.
final class DecodingException extends FrustbiteException {
  DecodingException([String? context])
    : super._(FrustbiteErrorCode.decodingError, context);
}

/// An underlying read failed.
final class FrustbiteIoException extends FrustbiteException {
  FrustbiteIoException([String? context])
    : super._(FrustbiteErrorCode.ioError, context);
}

/// A parameter is out of range.
final class InvalidParameterException extends FrustbiteException {
  InvalidParameterException([String? context])
    : super._(FrustbiteErrorCode.invalidParameter, context);
}

/// The path is empty, malformed or does not exist.
final class InvalidPathException extends FrustbiteException {
  InvalidPathException([String? context])
    : super._(FrustbiteErrorCode.invalidPath, context);
}

/// Internal or unclassified failure (invalid pointer, unknown code).
final class UnknownFrustbiteException extends FrustbiteException {
  UnknownFrustbiteException(super.code, [super.context]) : super._();
}

/// Throws the matching [FrustbiteException] for a non-zero native [value].
void checkError(int value, [String? context]) {
  if (value == 0) return;
  final code = FrustbiteErrorCode.fromValue(value);
  throw switch (code) {
    FrustbiteErrorCode.invalidPath => InvalidPathException(context),
    FrustbiteErrorCode.unsupportedFormat => UnsupportedFormatException(context),
    FrustbiteErrorCode.decodingError => DecodingException(context),
    FrustbiteErrorCode.ioError => FrustbiteIoException(context),
    FrustbiteErrorCode.invalidParameter => InvalidParameterException(context),
    _ => UnknownFrustbiteException(code, context),
  };
}
