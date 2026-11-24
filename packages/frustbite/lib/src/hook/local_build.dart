import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// Cargo features of the native crate, one per codec.
const supportedFormats = {'aac', 'alac', 'flac', 'mp3', 'opus', 'vorbis', 'wav'};

/// Reads the `formats` user define, or returns `null` when it is not set.
List<String>? readFormats(HookInput input) {
  final value = input.userDefines['formats'];
  if (value == null) return null;
  if (value is! List || value.any((format) => format is! String)) {
    throw FormatException('frustbite `formats` must be a list of format names, got: $value');
  }
  final formats = value.cast<String>().map((format) => format.toLowerCase()).toSet();
  final unknown = formats.difference(supportedFormats);
  if (unknown.isNotEmpty) {
    throw FormatException(
      'Unknown frustbite formats: ${unknown.join(', ')}. '
      'Supported: ${supportedFormats.join(', ')}',
    );
  }
  if (formats.isEmpty) {
    throw const FormatException('frustbite `formats` must enable at least one format');
  }
  return formats.toList()..sort();
}

/// Builds the native crate from source. When [formats] is set, only those
/// codecs are compiled in; otherwise all [supportedFormats] are.
Future<void> runLocalBuild(
  BuildInput input,
  BuildOutputBuilder output, {
  List<String>? formats,
}) async {
  final rustBuilder = RustBuilder(
    assetName: 'src/bindings/bindings.dart',
    cratePath: '../../native',
    enableDefaultFeatures: formats == null,
    features: formats ?? const [],
    extraCargoEnvironmentVariables: {
      'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER': 'aarch64-linux-gnu-gcc',
    },
  );

  await rustBuilder.run(input: input, output: output);
}
