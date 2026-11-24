import 'enums.dart';

/// Base class of every error reported by the Frustbite engine.
///
/// Catch it, or one of its subtypes. New subtypes may be added in minor
/// versions, so do not switch over it exhaustively without a default case.
/// Instances are created by the library only.
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
  UnsupportedFormatException._([String? context])
    : super._(FrustbiteErrorCode.unsupportedFormat, context);
}

/// The audio data is corrupt or does not match the expected format.
final class DecodingException extends FrustbiteException {
  DecodingException._([String? context])
    : super._(FrustbiteErrorCode.decodingError, context);
}

/// An underlying read failed.
final class FrustbiteIoException extends FrustbiteException {
  FrustbiteIoException._([String? context])
    : super._(FrustbiteErrorCode.ioError, context);
}

/// A parameter is out of range.
final class InvalidParameterException extends FrustbiteException {
  InvalidParameterException._([String? context])
    : super._(FrustbiteErrorCode.invalidParameter, context);
}

/// The path is empty, malformed or does not exist.
final class InvalidPathException extends FrustbiteException {
  InvalidPathException._([String? context])
    : super._(FrustbiteErrorCode.invalidPath, context);
}

/// Internal or unclassified failure (invalid pointer, unknown code).
final class UnknownFrustbiteException extends FrustbiteException {
  UnknownFrustbiteException._(super.code, [super.context]) : super._();
}

/// Creates the [FrustbiteException] matching [code], for the library's own
/// use: the subtype constructors are not public. Not exported.
FrustbiteException frustbiteError(
  FrustbiteErrorCode code, [
  String? context,
]) => switch (code) {
  FrustbiteErrorCode.invalidPath => InvalidPathException._(context),
  FrustbiteErrorCode.unsupportedFormat => UnsupportedFormatException._(context),
  FrustbiteErrorCode.decodingError => DecodingException._(context),
  FrustbiteErrorCode.ioError => FrustbiteIoException._(context),
  FrustbiteErrorCode.invalidParameter => InvalidParameterException._(context),
  _ => UnknownFrustbiteException._(code, context),
};

/// Throws the matching [FrustbiteException] for a non-zero native [value].
void checkError(int value, [String? context]) {
  if (value == 0) return;
  throw frustbiteError(FrustbiteErrorCode.fromValue(value), context);
}
