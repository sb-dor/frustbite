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

import 'dart:async';
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

/// Upper bound for the best-effort `rustup toolchain install`.
const _rustupTimeout = Duration(minutes: 5);

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
/// (so its `.cargo/config.toml` applies; a staged package passes its
/// `cargo-config.toml` with `--config`, see [stagedCargoConfig]) and a `--target-dir` under
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

  final hostEnvironment = Platform.environment;
  bool exists(String path) => File(path).existsSync();
  final cargo = findTool(
    'cargo',
    environment: hostEnvironment,
    windows: Platform.isWindows,
    fileExists: exists,
  );
  if (cargo == null) {
    throw CargoBuildException(
      'cargo was not found on PATH or in ${cargoBinDirs(hostEnvironment, windows: Platform.isWindows).join(', ')}. '
      'Install Rust from https://rustup.rs',
    );
  }
  // Tools found in the cargo bin directory (not on PATH) need it on PATH to
  // find each other (cargo -> rustc through the rustup proxies).
  final cargoBin = File(cargo).parent.path;
  final path = hostEnvironment[Platform.isWindows ? 'Path' : 'PATH'] ?? '';
  environment[Platform.isWindows ? 'Path' : 'PATH'] = path.isEmpty
      ? cargoBin
      : '$cargoBin${Platform.isWindows ? ';' : ':'}$path';

  // Best effort: `rustup toolchain install` without arguments reads the
  // crate's rust-toolchain.toml and installs the pinned toolchain, its
  // components and targets (rustup 1.28+ no longer does that on its own). On
  // failure cargo runs anyway and reports what is missing.
  final rustup = findTool(
    'rustup',
    environment: hostEnvironment,
    windows: Platform.isWindows,
    fileExists: exists,
  );
  if (rustup != null) {
    try {
      final process = await Process.start(
        rustup,
        ['toolchain', 'install'],
        workingDirectory: workingDirectory,
        environment: environment,
      );
      // Drain the output so the process cannot block on a full pipe.
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      // A stalled network must not hang the hook forever.
      await process.exitCode.timeout(
        _rustupTimeout,
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
    } on ProcessException {
      // Continue to cargo.
    }
  }

  final ProcessResult result;
  try {
    result = await Process.run(
      cargo,
      [
        'build',
        '--release',
        '--locked',
        ...cargoConfigArgs(crateDir),
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

/// The environment cargo needs for [triple], from the hook's code config.
Map<String, String> cargoEnvironment(CodeConfig code, String triple) =>
    cargoEnvironmentFor(
      code.targetOS,
      triple,
      ndkCompiler: code.cCompiler?.compiler,
      ndkArchiver: code.cCompiler?.archiver,
      androidNdkApi: code.targetOS == OS.android
          ? code.android.targetNdkApi
          : null,
      appleVersion: switch (code.targetOS) {
        OS.iOS => code.iOS.deploymentVersion,
        OS.macOS => code.macOS.deploymentVersion,
        _ => null,
      },
      windowsHost: Platform.isWindows,
    );

/// The environment cargo needs for [triple] on [os]: on Android the NDK
/// linker and C compiler ([ndkCompiler] is `code.cCompiler.compiler`, a clang
/// in the NDK's bin directory) and archiver, on Apple platforms the minimum
/// OS version. Linker flags are in `native/build.rs`, not here.
Map<String, String> cargoEnvironmentFor(
  OS os,
  String triple, {
  Uri? ndkCompiler,
  Uri? ndkArchiver,
  int? androidNdkApi,
  AppleVersion? appleVersion,
  bool windowsHost = false,
}) {
  final env = <String, String>{};
  final cargoKey = triple.toUpperCase().replaceAll('-', '_');
  final ccKey = triple.replaceAll('-', '_');
  switch (os) {
    case OS.android:
      if (ndkCompiler == null || ndkArchiver == null || androidNdkApi == null) {
        throw StateError(
          'the Android build needs the NDK C compiler (CCompilerConfig), '
          'which the Dart/Flutter build provides',
        );
      }
      final clang = ndkCompiler
          .resolve(
            ndkClang(
              ndkTriplePrefix(triple),
              androidNdkApi,
              windows: windowsHost,
            ),
          )
          .toFilePath();
      env['CARGO_TARGET_${cargoKey}_LINKER'] = clang;
      env['CC_$ccKey'] = clang;
      env['AR_$ccKey'] = ndkArchiver.toFilePath();
    case OS.macOS:
      env['MACOSX_DEPLOYMENT_TARGET'] = appleDeploymentTarget(appleVersion!);
    case OS.iOS:
      env['IPHONEOS_DEPLOYMENT_TARGET'] = appleDeploymentTarget(appleVersion!);
    default:
  }
  return env;
}

/// `major.minor`, for example `10.15` or `13.0`; the toolchains expect a
/// dotted version, not just the major number.
String appleDeploymentTarget(AppleVersion version) =>
    '${version.major}.${version.minor}';
