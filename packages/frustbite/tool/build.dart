import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:frustbite/src/hook/get_android_compiler_config.dart';
import 'package:frustbite/src/hook/target_versions.dart';
import 'package:frustbite/src/hook/targets.dart';

/// Builds release dynamic libraries for the given targets and copies each one
/// to `<output-dir>/<target>/<one file name>`, where the file name is
/// `libfrustbite.so`, `libfrustbite.dylib` or `frustbite.dll`.
///
/// ```sh
/// dart tool/build.dart [--zigbuild] [--release-paths] <output-dir> <target>...   # e.g. linux_x86_64 macos_arm64
/// dart tool/build.dart <output-dir> all
/// ```
///
/// `--release-paths` (CI release builds) remaps the home, rustup, cargo and
/// repository directories with `--remap-path-prefix`, so the binaries carry
/// no build machine paths. It sets `CARGO_ENCODED_RUSTFLAGS`, which replaces the config's
/// rustflags, so the Windows `+crt-static` flag is repeated there.
/// Only CI-built libraries should be staged for publishing.
///
/// Each library is built with `cargo build --release --target <triple>`; the
/// matching rustup target must be installed. Android targets need
/// `ANDROID_NDK_ROOT` or `ANDROID_NDK_HOME`.
///
/// Linux targets build with `cargo zigbuild --target <triple>.2.17` (glibc 2.17
/// floor) when `--zigbuild` is given or `FRUSTBITE_ZIGBUILD=1` is set. That
/// needs `pip install ziglang` and `cargo install cargo-zigbuild`. Without it
/// Linux uses plain `cargo build` against the host's glibc (local use only).
Future<void> main(List<String> rawArgs) async {
  final useZigbuild =
      rawArgs.contains('--zigbuild') ||
      Platform.environment['FRUSTBITE_ZIGBUILD'] == '1';
  final releasePaths = rawArgs.contains('--release-paths');
  final args = rawArgs
      .where((arg) => arg != '--zigbuild' && arg != '--release-paths')
      .toList();
  if (args.length < 2) {
    stderr
      ..writeln(
        'Usage: dart tool/build.dart [--zigbuild] [--release-paths] <output-dir> <target>... | all',
      )
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
    final triple = rustTriple(os, architecture, iOSSdk: iOSSdk);
    final environment = <String, String>{
      // Honour the minimum OS versions (see target_versions.dart).
      if (os == OS.macOS) 'MACOSX_DEPLOYMENT_TARGET': '$macOSTargetVersion',
      if (os == OS.iOS) 'IPHONEOS_DEPLOYMENT_TARGET': '$iOSTargetVersion',
    };
    if (releasePaths) {
      environment['CARGO_ENCODED_RUSTFLAGS'] = releaseRustflags(
        triple,
        hostEnvironment: Platform.environment,
        repositoryRoot: packageDir.parent.parent.path,
      );
    }
    if (os == OS.android) {
      final linker = getAndroidCompilerConfig(architecture).linker.toFilePath();
      environment['CARGO_TARGET_${triple.toUpperCase().replaceAll('-', '_')}_LINKER'] =
          linker;
    }

    // zigbuild takes the glibc version as a suffix of the target; the output
    // stays in target/<triple>/.
    final zigbuild = useZigbuild && os == OS.linux;
    // Plain `cargo build` for arm64 Linux on another host needs a cross
    // linker (zigbuild brings its own); it used to live in the crate's
    // `.cargo/config.toml`, where git-dependency builds on arm64 Linux hosts
    // picked it up.
    if (!zigbuild &&
        os == OS.linux &&
        architecture == Architecture.arm64 &&
        _hostArchitecture != Architecture.arm64) {
      environment['CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER'] =
          'aarch64-linux-gnu-gcc';
    }
    stdout.writeln('Building $name ($triple${zigbuild ? ', zigbuild' : ''})');
    final process = await Process.start(
      'cargo',
      zigbuild
          ? ['zigbuild', '--release', '--target', '$triple.$_linuxGlibc']
          : ['build', '--release', '--target', triple],
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
    final targetDir = Directory.fromUri(outputDir.uri.resolve('$name/'));
    await targetDir.create(recursive: true);
    final target = File.fromUri(
      targetDir.uri.resolve(os.dylibFileName('frustbite')),
    );
    if (!built.existsSync()) {
      stderr.writeln('Build succeeded but ${built.path} does not exist');
      exit(1);
    }
    await built.copy(target.path);
    stdout.writeln('  -> ${target.path}');
  }
}

/// The glibc floor of the Linux binaries (documented minimum).
const _linuxGlibc = '2.17';

final _targets = {
  for (final target in supportedTargets)
    getNameForTarget(target.$1, target.$2, target.$3): target,
};

/// The architecture of this host, for the local arm64 Linux cross build.
Architecture get _hostArchitecture {
  final version = Platform.version;
  return version.contains('arm64') || version.contains('aarch64')
      ? Architecture.arm64
      : Architecture.x64;
}

/// The flags for `--release-paths`, as `CARGO_ENCODED_RUSTFLAGS` (separated
/// by U+001F, so directories with spaces survive): remaps the build machine's
/// directories to fixed names. Later `--remap-path-prefix` flags win, so the
/// broad home directory comes first and the repository last. Any `RUSTFLAGS`
/// of the host stay in front.
String releaseRustflags(
  String triple, {
  required Map<String, String> hostEnvironment,
  required String repositoryRoot,
}) {
  final home =
      hostEnvironment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
  final cargoHome =
      hostEnvironment['CARGO_HOME'] ?? '$home${Platform.pathSeparator}.cargo';
  final rustupHome =
      hostEnvironment['RUSTUP_HOME'] ?? '$home${Platform.pathSeparator}.rustup';
  final remaps = <(String, String)>[
    if (home.isNotEmpty) (home, '/home'),
    (rustupHome, '/rustup'),
    (cargoHome, '/cargo'),
    (repositoryRoot, '/frustbite'),
  ];
  return [
    ...(hostEnvironment['RUSTFLAGS'] ?? '')
        .split(' ')
        .where((f) => f.isNotEmpty),
    if (triple.endsWith('-windows-msvc')) '-Ctarget-feature=+crt-static',
    for (final (from, to) in remaps) '--remap-path-prefix=$from=$to',
  ].join('\x1f');
}
