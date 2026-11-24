import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// Cargo features of the native crate, one per codec.
const supportedFormats = {
  'aac',
  'alac',
  'flac',
  'mp3',
  'opus',
  'vorbis',
  'wav',
};

/// Reads the `formats` user define, or returns `null` when it is not set.
List<String>? readFormats(HookInput input) {
  final value = input.userDefines['formats'];
  if (value == null) return null;
  if (value is! List || value.any((format) => format is! String)) {
    throw FormatException(
      'frustbite `formats` must be a list of format names, got: $value',
    );
  }
  final formats = value
      .cast<String>()
      .map((format) => format.toLowerCase())
      .toSet();
  final unknown = formats.difference(supportedFormats);
  if (unknown.isNotEmpty) {
    throw FormatException(
      'Unknown frustbite formats: ${unknown.join(', ')}. '
      'Supported: ${supportedFormats.join(', ')}',
    );
  }
  if (formats.isEmpty) {
    throw const FormatException(
      'frustbite `formats` must enable at least one format',
    );
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
    // native_toolchain_rust does not set deployment targets, so pass the
    // minimum OS versions the hook was configured with.
    extraCargoEnvironmentVariables: {
      ..._deploymentTargets(input),
      'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER': 'aarch64-linux-gnu-gcc',
    },
  );

  await rustBuilder.run(input: input, output: output);
}

Map<String, String> _deploymentTargets(BuildInput input) {
  if (!input.config.buildCodeAssets) return const {};
  final code = input.config.code;
  return switch (code.targetOS) {
    OS.macOS => {
      'MACOSX_DEPLOYMENT_TARGET': '${code.macOS.deploymentVersion.major}',
    },
    OS.iOS => {
      'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.deploymentVersion.major}',
    },
    _ => const {},
  };
}
