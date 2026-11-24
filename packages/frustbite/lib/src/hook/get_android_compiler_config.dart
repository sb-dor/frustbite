import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:frustbite/src/hook/target_versions.dart';

/// Locates the Android NDK clang toolchain for [architecture], using
/// `ANDROID_NDK_ROOT` or `ANDROID_NDK_HOME`.
///
/// Used when building the Android release binaries from source. The compiler
/// targets [androidTargetNdkApi] (pixer's compiler uses 35 while its code
/// config says 30; frustbite uses one value for both).
CCompilerConfig getAndroidCompilerConfig(Architecture architecture) {
  final ndkPath =
      Platform.environment['ANDROID_NDK_ROOT'] ??
      Platform.environment['ANDROID_NDK_HOME'];
  if (ndkPath == null) {
    throw StateError(
      'ANDROID_NDK_ROOT or ANDROID_NDK_HOME environment variable must be set',
    );
  }
  if (!Directory(ndkPath).existsSync()) {
    throw StateError('Android NDK not found at: $ndkPath');
  }

  final targetTriple = switch (architecture) {
    Architecture.arm => 'armv7a-linux-androideabi',
    Architecture.arm64 => 'aarch64-linux-android',
    Architecture.x64 => 'x86_64-linux-android',
    _ => throw UnsupportedError(
      'Unsupported Android architecture: $architecture',
    ),
  };

  final binPath = Uri.directory(
    '$ndkPath/toolchains/llvm/prebuilt/',
  ).resolve('${_hostTag()}/bin/');
  final ext = Platform.isWindows ? '.cmd' : '';
  final compiler = binPath.resolve(
    '$targetTriple$androidTargetNdkApi-clang$ext',
  );
  final archiver = binPath.resolve('llvm-ar$ext');

  if (!File.fromUri(compiler).existsSync()) {
    throw StateError('Compiler not found at: $compiler');
  }
  if (!File.fromUri(archiver).existsSync()) {
    throw StateError('Archiver not found at: $archiver');
  }

  return CCompilerConfig(
    compiler: compiler,
    archiver: archiver,
    linker: compiler,
  );
}

String _hostTag() {
  if (Platform.isLinux) return 'linux-x86_64';
  // NDK ships a universal x86_64 toolchain for macOS hosts, incl. Apple silicon.
  if (Platform.isMacOS) return 'darwin-x86_64';
  if (Platform.isWindows) return 'windows-x86_64';
  throw UnsupportedError(
    'Unsupported host platform: ${Platform.operatingSystem}',
  );
}
