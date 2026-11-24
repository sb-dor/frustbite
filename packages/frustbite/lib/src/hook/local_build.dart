// The cargo path of the build hook.
//
// It calls `cargo` directly instead of through `native_toolchain_rust`'s
// `RustBuilder`: that runs cargo without the crate as working directory, so
// the crate's `.cargo/config.toml` (`+crt-static` on Windows MSVC) would not
// apply, and it has no `--locked`, fixed NDK linker setup or per-API target
// directories. The environment setup (NDK clang from `code.cCompiler`, the
// target directory keyed by NDK API / deployment version) follows PlugFox/ws
// (MIT, https://github.com/PlugFox/ws, `native/hook/build.dart`); the code is
// written for frustbite. The Apple deployment-target helper is adapted from
// hawkkiller/pixer (MIT, Copyright (c) 2026 Michael Lazebny):
// https://github.com/hawkkiller/pixer

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:frustbite/src/hook/resolve.dart';
import 'package:frustbite/src/hook/targets.dart';
import 'package:hooks/hooks.dart';

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

/// The cargo arguments that select [formats]; none for the default (all)
/// codecs.
List<String> cargoFeatureArgs(List<String>? formats) => formats == null
    ? const []
    : ['--no-default-features', '--features', formats.join(',')];

/// Why the cargo path could not provide a library: cargo is missing, failed,
/// or the target has no toolchain set up.
class CargoBuildException implements Exception {
  CargoBuildException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds the crate in [crateDir] for the hook's target and copies the
/// library to `outputDirectory/<file name>`. When [formats] is set only those
/// codecs are compiled in; otherwise all [supportedFormats] are.
///
/// Runs `cargo build --release --locked` with the crate as working directory
/// (so its `.cargo/config.toml` applies) and a `--target-dir` under
/// `outputDirectoryShared/cargo/<key>/`, where the key holds the NDK API or
/// the Apple deployment version: cargo does not fingerprint those.
///
/// Throws a [CargoBuildException] for every failure.
Future<Uri> cargoBuild(
  BuildInput input,
  Directory crateDir, {
  List<String>? formats,
}) async {
  final code = input.config.code;
  final String triple;
  final Map<String, String> environment;
  final String key;
  try {
    triple = rustTriple(
      code.targetOS,
      code.targetArchitecture,
      iOSSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
    );
    environment = cargoEnvironment(code, triple);
    key = cargoTargetKey(
      code.targetOS,
      androidNdkApi: code.targetOS == OS.android
          ? code.android.targetNdkApi
          : null,
      appleVersion: switch (code.targetOS) {
        OS.iOS => code.iOS.deploymentVersion,
        OS.macOS => code.macOS.deploymentVersion,
        _ => null,
      },
    );
  } on Object catch (e) {
    throw CargoBuildException('$e');
  }

  final fileName = libraryFileName(code.targetOS);
  final targetDir = input.outputDirectoryShared.resolve('cargo/$key/');
  final workingDirectory = crateDir.absolute.path;

  // Best effort: lets rustup fetch the toolchain and targets that the crate's
  // rust-toolchain.toml pins. Without rustup this is a no-op.
  try {
    await Process.run('rustup', [
      'show',
      'active-toolchain',
    ], workingDirectory: workingDirectory);
  } on ProcessException {
    // No rustup: a system cargo is used as is.
  }

  final ProcessResult result;
  try {
    result = await Process.run(
      'cargo',
      [
        'build',
        '--release',
        '--locked',
        '--target',
        triple,
        '--target-dir',
        targetDir.toFilePath(),
        ...cargoFeatureArgs(formats),
      ],
      workingDirectory: workingDirectory,
      environment: environment,
    );
  } on ProcessException catch (e) {
    throw CargoBuildException('cargo could not be started (${e.message})');
  }
  if (result.exitCode != 0) {
    throw CargoBuildException(
      'cargo build for $triple failed with exit code ${result.exitCode}:\n'
      '${result.stdout}\n${result.stderr}',
    );
  }

  final built = File.fromUri(targetDir.resolve('$triple/release/$fileName'));
  if (!built.existsSync()) {
    throw CargoBuildException(
      'cargo build succeeded but ${built.path} does not exist',
    );
  }
  final copy = File.fromUri(input.outputDirectory.resolve(fileName));
  await copy.parent.create(recursive: true);
  await built.copy(copy.path);
  return copy.uri;
}

/// The environment cargo needs for [triple]: on Android the NDK linker and
/// C compiler (taken from `code.cCompiler`), on Apple platforms the minimum
/// OS version. Linker flags are in `native/build.rs`, not here.
Map<String, String> cargoEnvironment(CodeConfig code, String triple) {
  final env = <String, String>{};
  final cargoKey = triple.toUpperCase().replaceAll('-', '_');
  final ccKey = triple.replaceAll('-', '_');
  switch (code.targetOS) {
    case OS.android:
      final compiler = code.cCompiler?.compiler;
      if (compiler == null) {
        throw StateError(
          'the Android build needs the NDK C compiler (CCompilerConfig), '
          'which the Dart/Flutter build provides',
        );
      }
      final clang = compiler
          .resolve(
            ndkClang(
              ndkTriplePrefix(triple),
              code.android.targetNdkApi,
              windows: Platform.isWindows,
            ),
          )
          .toFilePath();
      env['CARGO_TARGET_${cargoKey}_LINKER'] = clang;
      env['CC_$ccKey'] = clang;
      env['AR_$ccKey'] = compiler
          .resolve(Platform.isWindows ? 'llvm-ar.exe' : 'llvm-ar')
          .toFilePath();
    case OS.macOS:
      env['MACOSX_DEPLOYMENT_TARGET'] = appleDeploymentTarget(
        code.macOS.deploymentVersion,
      );
    case OS.iOS:
      env['IPHONEOS_DEPLOYMENT_TARGET'] = appleDeploymentTarget(
        code.iOS.deploymentVersion,
      );
    default:
  }
  return env;
}

/// `major.minor`, for example `10.15` or `13.0`; the toolchains expect a
/// dotted version, not just the major number.
String appleDeploymentTarget(AppleVersion version) =>
    '${version.major}.${version.minor}';
