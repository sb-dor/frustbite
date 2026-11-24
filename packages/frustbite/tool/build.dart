import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:frustbite/src/hook/download_asset.dart';
import 'package:frustbite/src/hook/get_android_compiler_config.dart';
import 'package:frustbite/src/hook/target_versions.dart';
import 'package:frustbite/src/hook/targets.dart';

/// Builds release dynamic libraries for the given targets and copies them,
/// named like the GitHub release assets, into a directory.
///
/// ```sh
/// dart tool/build.dart <output-dir> <target>...   # e.g. linux_x86_64 macos_arm64
/// dart tool/build.dart <output-dir> all
/// ```
///
/// Each library is built with `cargo build --release --target <triple>`; the
/// matching rustup target must be installed. Android targets need
/// `ANDROID_NDK_ROOT` or `ANDROID_NDK_HOME`.
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr
      ..writeln('Usage: dart tool/build.dart <output-dir> <target>... | all')
      ..writeln('Targets: ${_targets.keys.join(', ')}');
    exit(64);
  }
  final outputDir = Directory(args.first).absolute;
  final names = args.skip(1).toList();
  final selected = names.contains('all') ? _targets.keys.toList() : names;
  final unknown = selected.where((name) => !_targets.containsKey(name));
  if (unknown.isNotEmpty) {
    stderr.writeln(
      'Unknown targets: ${unknown.join(', ')}. '
      'Known: ${_targets.keys.join(', ')}',
    );
    exit(64);
  }

  final packageDir = File.fromUri(Platform.script).absolute.parent.parent;
  final nativeDir = Directory.fromUri(packageDir.uri.resolve('../../native/'));
  await outputDir.create(recursive: true);

  for (final name in selected) {
    final (os, architecture, iOSSdk) = _targets[name]!;
    final triple = _rustTriple(os, architecture, iOSSdk);
    final environment = <String, String>{
      // Honour the minimum OS versions (see target_versions.dart).
      if (os == OS.macOS) 'MACOSX_DEPLOYMENT_TARGET': '$macOSTargetVersion',
      if (os == OS.iOS) 'IPHONEOS_DEPLOYMENT_TARGET': '$iOSTargetVersion',
    };
    if (os == OS.android) {
      final linker = getAndroidCompilerConfig(architecture).linker.toFilePath();
      environment['CARGO_TARGET_${triple.toUpperCase().replaceAll('-', '_')}_LINKER'] =
          linker;
    }

    stdout.writeln('Building $name ($triple)');
    final process = await Process.start(
      'cargo',
      ['build', '--release', '--target', triple],
      workingDirectory: nativeDir.path,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) exit(code);

    // The crate's cdylib is `frustbite` (`libfrustbite.so`, `frustbite.dll`).
    final built = File.fromUri(
      nativeDir.uri.resolve(
        'target/$triple/release/${os.dylibFileName('frustbite')}',
      ),
    );
    final target = File.fromUri(
      outputDir.uri.resolve(assetFileName(os, architecture, iOSSdk)),
    );
    if (!built.existsSync()) {
      stderr.writeln('Build succeeded but ${built.path} does not exist');
      exit(1);
    }
    await built.copy(target.path);
    stdout.writeln('  -> ${target.path}');
  }
}

final _targets = {
  for (final target in supportedTargets)
    getNameForTarget(target.$1, target.$2, target.$3): target,
};

String _rustTriple(OS os, Architecture architecture, IOSSdk? iOSSdk) {
  switch ((os, architecture, iOSSdk)) {
    case (OS.android, Architecture.arm, _):
      return 'armv7-linux-androideabi';
    case (OS.android, Architecture.arm64, _):
      return 'aarch64-linux-android';
    case (OS.android, Architecture.x64, _):
      return 'x86_64-linux-android';
    case (OS.iOS, Architecture.arm64, IOSSdk.iPhoneOS):
      return 'aarch64-apple-ios';
    case (OS.iOS, Architecture.arm64, IOSSdk.iPhoneSimulator):
      return 'aarch64-apple-ios-sim';
    case (OS.iOS, Architecture.x64, _):
      return 'x86_64-apple-ios';
    case (OS.linux, Architecture.arm64, _):
      return 'aarch64-unknown-linux-gnu';
    case (OS.linux, Architecture.x64, _):
      return 'x86_64-unknown-linux-gnu';
    case (OS.macOS, Architecture.arm64, _):
      return 'aarch64-apple-darwin';
    case (OS.macOS, Architecture.x64, _):
      return 'x86_64-apple-darwin';
    case (OS.windows, Architecture.arm64, _):
      return 'aarch64-pc-windows-msvc';
    case (OS.windows, Architecture.x64, _):
      return 'x86_64-pc-windows-msvc';
  }
  throw UnimplementedError('Unsupported target: $os $architecture $iOSSdk');
}
