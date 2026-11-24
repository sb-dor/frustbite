// The pure decisions of the build hook: which source to use, where the
// bundled library lives, whether it is intact, where the crate is. Kept free
// of the hook runner so they can be tested directly.
//
// The resolution design follows PlugFox/ws (MIT, https://github.com/PlugFox/ws,
// `native/hook/build.dart`); the code is written for frustbite.

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:frustbite/src/hook/targets.dart';

/// The library name; the file name per OS comes from [libraryFileName].
const libraryName = 'frustbite';

/// `libfrustbite.so`, `libfrustbite.dylib` or `frustbite.dll`: the same on
/// every architecture of an OS. The target lives only in the directory name
/// (see [prebuiltDirName]), so Flutter sees one framework name on Apple
/// platforms.
String libraryFileName(OS os) => os.dylibFileName(libraryName);

/// Where the native library comes from (the `source` user define).
enum Source {
  /// The bundled prebuilt library if there is one, else cargo.
  auto,

  /// The bundled prebuilt library only.
  prebuilt,

  /// Cargo only.
  build,

  /// No asset at all. The app then fails at its first frustbite call with the
  /// ordinary missing-library error.
  none,
}

/// Parses the `source` user define: one value, or a map of OS name to value
/// with an optional `default` (`{default: prebuilt, linux: build}`).
///
/// [localBuild] is the `local_build: true` alias for [Source.build] and
/// [hasFormats] tells that a `formats` list was given, which also needs a
/// source build: the prebuilt library has every codec. Anything unknown
/// throws, so a typo can never silently mean `auto`.
Source parseSource(
  Object? value,
  OS os, {
  bool localBuild = false,
  bool hasFormats = false,
}) {
  if (value is Map<Object?, Object?>) {
    final valid = {...OS.values.map((o) => o.name), 'default'};
    final unknown = value.keys.where((key) => !valid.contains(key));
    if (unknown.isNotEmpty) {
      throw ArgumentError(
        'frustbite: user-define `source` map has unknown keys '
        '${unknown.join(', ')}. Valid keys: ${valid.join(', ')}',
      );
    }
  }
  final picked = switch (value) {
    null => null,
    final Map<Object?, Object?> map => map[os.name] ?? map['default'],
    _ => value,
  };
  final Source? explicit;
  if (picked == null) {
    explicit = null;
  } else {
    explicit = Source.values.asNameMap()[picked];
    if (explicit == null) {
      throw ArgumentError(
        'frustbite: user-define `source` must be one of '
        '${Source.values.map((s) => s.name).join(', ')} (or a map of OS name '
        'to one of them), got $value',
      );
    }
  }

  if (localBuild && explicit != null && explicit != Source.build) {
    throw ArgumentError(
      'frustbite: `local_build: true` means `source: build`, which conflicts '
      'with `source: ${explicit.name}`. Drop one of them.',
    );
  }
  if (hasFormats && explicit == Source.prebuilt) {
    throw ArgumentError(
      'frustbite: `formats` needs a source build (the prebuilt library has '
      'every codec), which conflicts with `source: prebuilt`.',
    );
  }
  if (explicit == Source.none) return Source.none;
  if (localBuild || hasFormats) return Source.build;
  return explicit ?? Source.auto;
}

/// The directory of a target under `prebuilt/`: `<os>-<arch>[-sim]`, from
/// `OS.name` and `Architecture.name` (`macos-arm64`, `ios-arm64-sim`,
/// `android-arm`, `windows-x64`).
///
/// This is the canonical naming of the package. The older `<os>_<arch>` names
/// of [getNameForTarget] only remain where `tool/build.dart` and the release
/// asset names use them; [prebuiltDirForTargetName] maps between the two.
String prebuiltDirName(OS os, Architecture architecture, {IOSSdk? iOSSdk}) {
  final sim = os == OS.iOS && iOSSdk == IOSSdk.iPhoneSimulator;
  return '${os.name}-${architecture.name}${sim ? '-sim' : ''}';
}

/// The `prebuilt/` directory for a target name of [getNameForTarget], such as
/// `macos_x86_64` (`macos-x64`). The one mapping between the two namings.
String prebuiltDirForTargetName(String targetName) {
  for (final (os, architecture, iOSSdk) in supportedTargets) {
    if (getNameForTarget(os, architecture, iOSSdk) == targetName) {
      return prebuiltDirName(os, architecture, iOSSdk: iOSSdk);
    }
  }
  throw ArgumentError.value(targetName, 'targetName', 'Unknown target');
}

/// Checks [file] against its entry [key] (`<dir>/<file name>`) in the
/// `checksums.json` at [checksums].
///
/// A missing `checksums.json` or entry is an error, never a skipped check: a
/// library without a checksum is not loaded.
Future<void> verifyPrebuilt(
  File file, {
  required File checksums,
  required String key,
}) async {
  if (!checksums.existsSync()) {
    throw StateError(
      'frustbite: prebuilt/checksums.json is missing next to prebuilt/$key. '
      'A library without a checksum is not loaded. Reinstall the package, or '
      'use `source: build`, or `library: <path>` for your own build.',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(await checksums.readAsString());
  } on FormatException catch (e) {
    throw StateError(
      'frustbite: prebuilt/checksums.json is not valid JSON (${e.message}). '
      'The package archive is corrupt; reinstall it.',
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw StateError(
      'frustbite: prebuilt/checksums.json must be a JSON object mapping '
      '`<target>/<file>` to its sha256. The package archive is corrupt; '
      'reinstall it.',
    );
  }
  final expected = decoded[key];
  if (expected is! String) {
    throw StateError(
      'frustbite: prebuilt/checksums.json has no checksum for $key. '
      'The package archive is incomplete; reinstall it.',
    );
  }
  final actual = sha256.convert(await file.readAsBytes()).toString();
  if (expected != actual) {
    throw StateError(
      'frustbite: checksum mismatch for prebuilt/$key (expected $expected, '
      'got $actual). The package archive is corrupt or was modified; clear '
      'the pub cache entry and reinstall.',
    );
  }
}

/// Where the Rust crate is, or `null`: first `<packageRoot>/rust/` (the
/// published package), then `<packageRoot>/../../native/` (a repository
/// checkout or a git dependency). The fallback only counts when its
/// `Cargo.toml` declares the package `frustbite`, so an unrelated `native/`
/// next to a path dependency is never built.
Directory? findCrateDir(Uri packageRoot) {
  for (final (path, checkName) in const [
    ('rust/', false),
    ('../../native/', true),
  ]) {
    final dir = Directory.fromUri(packageRoot.resolve(path));
    final manifest = File.fromUri(dir.uri.resolve('Cargo.toml'));
    if (!manifest.existsSync()) continue;
    if (checkName &&
        cargoPackageName(manifest.readAsStringSync()) != libraryName) {
      continue;
    }
    return dir;
  }
  return null;
}

/// The file name of the cargo config a staged package carries in `rust/`.
///
/// pub leaves hidden files and directories out of the archive, so the crate's
/// `.cargo/config.toml` (`+crt-static` on Windows MSVC) cannot ship as it is.
/// `tool/stage_package.dart` writes the same settings to this visible file,
/// and [cargoConfigArgs] passes it to cargo.
const stagedCargoConfig = 'cargo-config.toml';

/// The cargo arguments that load the staged config of [crateDir]; none in a
/// repository checkout, where cargo reads `.cargo/config.toml` itself.
List<String> cargoConfigArgs(Directory crateDir) {
  final config = File.fromUri(crateDir.absolute.uri.resolve(stagedCargoConfig));
  return config.existsSync() ? ['--config', config.path] : const [];
}

/// The `name` of the `[package]` table in a Cargo.toml text, or `null`.
String? cargoPackageName(String manifest) {
  final name = RegExp(r'''^name\s*=\s*(["'])(.*?)\1''');
  var inPackage = false;
  for (final raw in const LineSplitter().convert(manifest)) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      inPackage = line.startsWith('[package]');
    } else if (inPackage) {
      final match = name.firstMatch(line);
      if (match != null) return match.group(2);
    }
  }
  return null;
}

/// Finds the executable [name] (`cargo`, `rustup`): on `PATH` first, then in
/// `$CARGO_HOME/bin`, then in `~/.cargo/bin` (`%USERPROFILE%\.cargo\bin` on
/// Windows). GUI-launched builds (an Xcode build phase, Android Studio on
/// macOS) often lack `~/.cargo/bin` on `PATH`.
///
/// Returns the path to run, or `null` when none exists. [environment] and
/// [fileExists] are injectable for tests.
String? findTool(
  String name, {
  required Map<String, String> environment,
  required bool windows,
  required bool Function(String path) fileExists,
}) {
  final file = windows ? '$name.exe' : name;
  final separator = windows ? r'\' : '/';
  final pathVariable = windows ? ';' : ':';
  final dirs = [
    ...?environment[windows ? 'Path' : 'PATH']?.split(pathVariable),
    if (windows) ...?environment['PATH']?.split(pathVariable),
    ...cargoBinDirs(environment, windows: windows),
  ];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final path = dir.endsWith(separator) ? '$dir$file' : '$dir$separator$file';
    if (fileExists(path)) return path;
  }
  return null;
}

/// `$CARGO_HOME/bin` and `~/.cargo/bin`, where rustup puts its proxies.
List<String> cargoBinDirs(
  Map<String, String> environment, {
  required bool windows,
}) {
  final separator = windows ? r'\' : '/';
  final home = environment[windows ? 'USERPROFILE' : 'HOME'];
  final cargoHome = environment['CARGO_HOME'];
  return [
    if (cargoHome != null && cargoHome.isNotEmpty) '$cargoHome${separator}bin',
    if (home != null && home.isNotEmpty) '$home$separator.cargo${separator}bin',
  ];
}

/// What, besides the triple, makes a cargo build differ: the NDK API on
/// Android, the deployment target on Apple platforms. Cargo does not
/// fingerprint either, so each gets its own target directory; reusing one
/// built for a newer level would fail to load on an older OS.
String cargoTargetKey(OS os, {int? androidNdkApi, AppleVersion? appleVersion}) {
  switch (os) {
    case OS.android:
      if (androidNdkApi == null) {
        throw ArgumentError.notNull('androidNdkApi');
      }
      return 'android-$androidNdkApi';
    case OS.iOS || OS.macOS:
      if (appleVersion == null) throw ArgumentError.notNull('appleVersion');
      return '${os.name.toLowerCase()}-${appleVersion.major}.'
          '${appleVersion.minor}';
    default:
      return 'default';
  }
}

/// The NDK clang wrapper for [triplePrefix] and [api]; a `.cmd` script on
/// Windows hosts.
String ndkClang(String triplePrefix, int api, {required bool windows}) =>
    '$triplePrefix$api-clang${windows ? '.cmd' : ''}';

/// The NDK names its armv7 wrappers `armv7a-...`, not the Rust `armv7-...`.
String ndkTriplePrefix(String rustTriple) =>
    rustTriple == 'armv7-linux-androideabi'
    ? 'armv7a-linux-androideabi'
    : rustTriple;

/// The entries of [uris] that are files that exist.
///
/// The hooks runner treats a missing dependency as "modified just now" and
/// reruns the hook on every build, so only existing files are registered.
List<Uri> existingFiles(Iterable<Uri> uris) => [
  for (final uri in uris)
    if (File.fromUri(uri).existsSync()) uri,
];

/// The files whose change must rerun the hook: the crate's manifest, lock
/// file, build script, toolchain and cargo configs, its `src/**/*.rs`, the
/// bundled `checksums.json` and the target's prebuilt library. Only files
/// that exist.
List<Uri> hookDependencies({
  required Uri packageRoot,
  required Directory? crateDir,
  required String prebuiltDir,
  required String fileName,
}) {
  final prebuilt = packageRoot.resolve('prebuilt/');
  return existingFiles([
    prebuilt.resolve('checksums.json'),
    prebuilt.resolve('$prebuiltDir/$fileName'),
    if (crateDir != null) ...[
      crateDir.uri.resolve('Cargo.toml'),
      crateDir.uri.resolve('Cargo.lock'),
      crateDir.uri.resolve('build.rs'),
      crateDir.uri.resolve('rust-toolchain.toml'),
      crateDir.uri.resolve('.cargo/config.toml'),
      crateDir.uri.resolve(stagedCargoConfig),
      if (Directory.fromUri(crateDir.uri.resolve('src/')).existsSync())
        for (final entity in Directory.fromUri(
          crateDir.uri.resolve('src/'),
        ).listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.rs')) entity.uri,
    ],
  ]);
}

/// The error for a target nothing can provide a library for ([reason] says
/// why), listing the ways out.
String noLibraryMessage(String target, {required String reason}) =>
    'frustbite: no native library for $target ($reason).\n'
    '\n'
    'frustbite has no pure-Dart fallback. Pick one of:\n'
    '  - `source: prebuilt`: use the library bundled in the package. It '
    'needs the published package from pub.dev; a git or path dependency has '
    'no prebuilt/ directory.\n'
    '  - `source: build`: build the Rust crate. It needs Rust '
    '(https://rustup.rs) and, for $target, its toolchain.\n'
    '  - `library: <path>`: use your own build of the library.\n'
    '  - `source: none`: ship no library (frustbite then fails at its first '
    'call).\n'
    '\n'
    'In the app\'s pubspec.yaml:\n'
    '\n'
    'hooks:\n'
    '  user_defines:\n'
    '    frustbite:\n'
    '      source: build   # or prebuilt, none\n'
    '      # library: path/to/libfrustbite\n';
