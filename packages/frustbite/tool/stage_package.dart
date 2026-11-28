// Stages the frustbite package for publishing, outside the repository.
//
// The published archive differs from the git checkout: it holds the prebuilt
// native libraries under `prebuilt/` and the Rust crate under `rust/` (the
// hook's cargo fallback builds from it), and it must not be assembled inside
// the repository, where pub would apply the repository's ignore files.
//
//   dart tool/stage_package.dart --from-dir <dir> --out <dir> [--allow-partial]
//   dart tool/stage_package.dart --from-release <tag> --out <dir>
//
// `--from-dir` takes the output of `tool/build.dart`: `<dir>/<target>/<file>`
// with the targets of `getNameForTarget` (`macos_arm64`). `--from-release`
// downloads the flattened release assets (`libfrustbite_macos_arm64.dylib`)
// with `gh`, un-flattens them and checks them against the release's
// `checksums.json`; the working tree must be the clean checkout of that tag,
// since the Dart and Rust sources are staged from it. `--allow-partial` accepts fewer than 12 libraries and is
// for local testing only; CI never passes it.
//
// What is staged:
//   - the git-tracked files of packages/frustbite, minus `test/fixtures/` and
//     `tool/` (the package's `.pubignore` excludes both as well);
//     `resolution: workspace` is dropped from pubspec.yaml, which the staged
//     copy, outside the workspace, cannot use;
//   - from native/, the files `cargo build --locked` needs, as `rust/`:
//     Cargo.toml (plus an empty `[workspace]` table if it has none, so a pub
//     cache under someone's cargo workspace still builds), Cargo.lock,
//     build.rs, src/**, a trimmed `rust-toolchain.toml` (the same channel,
//     `profile = "minimal"`, no components or targets: the repository's holds
//     the CI toolchain, clippy, rustfmt and 13 targets, hundreds of MB that a
//     source build from pub.dev must not install) and
//     `cargo-config.toml`: the Windows `+crt-static` tables of
//     `.cargo/config.toml`. pub leaves hidden files out of the archive, so
//     the hook passes that visible copy to cargo with `--config`. Not
//     `target/`, `tests/`, `tool/`, cbindgen.toml (the header is generated
//     by hand, not by the build) or the research notes;
//   - the libraries as `prebuilt/<os>-<arch>[-sim]/<one file name>`, and
//     `prebuilt/checksums.json` (sorted keys, `<dir>/<file>` to sha256).
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:frustbite/src/hook/resolve.dart';
import 'package:frustbite/src/hook/targets.dart';
import 'package:path/path.dart' as p;

/// Packaged for pub (`name/…` relative paths) from the git-tracked files of
/// the package; these directories never are.
const _packageExcludes = [
  'test/fixtures/',
  'test/stage_package_test.dart', // imports tool/, which is not published
  'tool/',
];

/// The files of native/ the staged `rust/` holds (`src/` as a prefix).
const _crateFiles = {'Cargo.toml', 'Cargo.lock', 'build.rs'};

/// Written trimmed, not copied: see [stagedToolchain].
const _toolchainFile = 'rust-toolchain.toml';

/// The tracked config the staged `cargo-config.toml` is made from.
const _cargoConfig = '.cargo/config.toml';

/// The number of libraries a complete package holds.
final libraryCount = supportedTargets.length;

/// Why staging failed. The message is for the user.
class StageException implements Exception {
  StageException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One library target: its name for `tool/build.dart` and the release, its
/// directory under `prebuilt/` and its one file name.
class StageTarget {
  StageTarget(this.os, this.name, this.dir, this.fileName);

  factory StageTarget.of((OS, Architecture, IOSSdk?) target) {
    final (os, architecture, sdk) = target;
    final name = getNameForTarget(os, architecture, sdk);
    return StageTarget(
      os,
      name,
      prebuiltDirForTargetName(name),
      libraryFileName(os),
    );
  }

  final OS os;
  final String name;
  final String dir;
  final String fileName;

  /// The key in `checksums.json`.
  String get key => '$dir/$fileName';

  /// The release asset name: the target goes before the extension
  /// (`libfrustbite_macos_arm64.dylib`, `frustbite_windows_x86_64.dll`).
  String get releaseAsset {
    final dot = fileName.lastIndexOf('.');
    return '${fileName.substring(0, dot)}_$name${fileName.substring(dot)}';
  }
}

/// The 12 targets, in the order of [supportedTargets].
List<StageTarget> get stageTargets => [
  for (final target in supportedTargets) StageTarget.of(target),
];

/// Stages the package into [out] from [fromDir] (the layout of
/// `tool/build.dart`). Returns the staged libraries by their checksum key.
///
/// [packageDir] is `packages/frustbite`; the repository root is two levels
/// above it. Throws [StageException].
Future<Map<String, String>> stagePackage({
  required Directory packageDir,
  required Directory fromDir,
  required Directory out,
  bool allowPartial = false,
}) async {
  final root = packageDir.parent.parent.absolute;
  final nativeDir = Directory(p.join(root.path, 'native'));
  if (!nativeDir.existsSync()) {
    throw StageException('native/ not found at ${nativeDir.path}');
  }
  final target = out.absolute;
  if (p.isWithin(root.path, target.path) || p.equals(root.path, target.path)) {
    throw StageException(
      'Stage outside the repository, not in ${target.path}: pub would apply '
      "the repository's ignore files.",
    );
  }
  if (target.existsSync() && target.listSync().isNotEmpty) {
    throw StageException('${target.path} is not empty. Remove it first.');
  }

  // Collect and check the libraries before anything is written.
  final libraries = _collectLibraries(fromDir, allowPartial: allowPartial);

  await target.create(recursive: true);

  // 1. The package.
  for (final file in await _gitFiles(packageDir)) {
    if (_packageExcludes.any(file.startsWith)) continue;
    _copy(File(p.join(packageDir.path, file)), File(p.join(target.path, file)));
  }
  final pubspec = File(p.join(target.path, 'pubspec.yaml'));
  final lines = pubspec.readAsLinesSync();
  if (lines.where((line) => line == 'resolution: workspace').length != 1) {
    throw StageException(
      'pubspec.yaml has no single `resolution: workspace` line to drop',
    );
  }
  pubspec.writeAsStringSync(
    '${lines.where((line) => line != 'resolution: workspace').join('\n')}\n',
  );
  for (final required in ['THIRD_PARTY_LICENSES.md', 'LICENSE', '.pubignore']) {
    if (!File(p.join(target.path, required)).existsSync()) {
      throw StageException('$required is not tracked in the package');
    }
  }

  // 2. The crate.
  final crate = await _gitFiles(nativeDir);
  for (final required in [..._crateFiles, _toolchainFile]) {
    if (!crate.contains(required)) {
      throw StageException('native/$required is not tracked by git');
    }
  }
  if (!crate.contains(_cargoConfig)) {
    throw StageException('native/$_cargoConfig is not tracked by git');
  }
  File(p.join(target.path, 'rust', stagedCargoConfig))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      stagedConfig(
        File(p.join(nativeDir.path, _cargoConfig)).readAsStringSync(),
      ),
    );
  for (final file in crate) {
    if (_crateFiles.contains(file) || file.startsWith('src/')) {
      _copy(
        File(p.join(nativeDir.path, file)),
        File(p.join(target.path, 'rust', file)),
      );
    }
  }
  final manifest = File(p.join(target.path, 'rust', 'Cargo.toml'));
  manifest.writeAsStringSync(stagedManifest(manifest.readAsStringSync()));
  File(p.join(target.path, 'rust', _toolchainFile)).writeAsStringSync(
    stagedToolchain(
      File(p.join(nativeDir.path, _toolchainFile)).readAsStringSync(),
    ),
  );

  // 3. The libraries and 4. their checksums.
  final checksums = <String, String>{};
  for (final entry in libraries.entries) {
    final staged = File(p.join(target.path, 'prebuilt', entry.key));
    _copy(entry.value, staged);
    checksums[entry.key] = sha256.convert(staged.readAsBytesSync()).toString();
  }
  final sorted = {
    for (final key in checksums.keys.toList()..sort()) key: checksums[key],
  };
  File(p.join(target.path, 'prebuilt', 'checksums.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(sorted)}\n',
  );
  return checksums;
}

/// The `rust-toolchain.toml` of the staged package, from the text of
/// `native/rust-toolchain.toml`: the same `channel`, `profile = "minimal"`, no
/// components and no targets. The repository's file lists everything CI needs
/// (clippy, rustfmt, wasm, Android, iOS, ...), and rustup would install all of
/// it for a source build from pub.dev. The hook adds the one target it needs.
String stagedToolchain(String toolchain) {
  final channel = rustToolchainChannel(toolchain);
  if (channel == null) {
    throw StageException('native/$_toolchainFile has no `channel`');
  }
  return '# Staged from native/$_toolchainFile by tool/stage_package.dart: the '
      'pinned channel\n# only. The hook installs the one target it builds '
      'for.\n[toolchain]\nchannel = "$channel"\nprofile = "minimal"\n';
}

/// The Cargo.toml text for the staged crate: an empty `[workspace]` table is
/// appended when there is none. Without it cargo walks up from `rust/` and
/// refuses to build a crate that sits under someone else's workspace (a pub
/// cache inside a monorepo).
String stagedManifest(String manifest) {
  final hasWorkspace = const LineSplitter()
      .convert(manifest)
      .any((line) => line.trim().startsWith('[workspace'));
  if (hasWorkspace) return manifest;
  return '${manifest.trimRight()}\n\n[workspace]\n';
}

/// The `cargo-config.toml` of the staged package, from the text of
/// `native/.cargo/config.toml`: its Windows MSVC tables (with the comments
/// above them) and nothing else.
String stagedConfig(String config) {
  final tables = <List<String>>[[]];
  for (final line in const LineSplitter().convert(config)) {
    // A table starts at its header; the comments above it belong to it, so
    // the pending comment lines move to the new table.
    if (line.startsWith('[')) {
      final lead = <String>[];
      final current = tables.last;
      while (current.isNotEmpty && current.last.startsWith('#')) {
        lead.insert(0, current.removeLast());
      }
      tables.add([...lead, line]);
    } else {
      tables.last.add(line);
    }
  }
  final windows = [
    for (final table in tables)
      if (table.any(
        (line) => line.startsWith('[target.') && line.contains('-windows-msvc'),
      ))
        table.join('\n').trimRight(),
  ];
  if (windows.length != 2 || windows.any((t) => !t.contains('+crt-static'))) {
    throw StageException(
      'native/$_cargoConfig must hold the two Windows MSVC tables with '
      '+crt-static; found ${windows.length}',
    );
  }
  return '# Staged from native/$_cargoConfig by tool/stage_package.dart; the hook '
      'passes it to cargo\n# with --config (pub leaves hidden directories out '
      'of the archive).\n\n${windows.join('\n\n')}\n';
}

/// `<dir>/<file>` to the source file, from a `tool/build.dart` output dir.
Map<String, File> _collectLibraries(
  Directory fromDir, {
  required bool allowPartial,
}) {
  if (!fromDir.existsSync()) {
    throw StageException('${fromDir.path} does not exist');
  }
  final targets = stageTargets;
  final known = {for (final target in targets) target.name: target};
  final libraries = <String, File>{};
  for (final entity in fromDir.listSync()) {
    final name = p.basename(entity.path);
    final target = known[name];
    if (target == null || entity is! Directory) {
      throw StageException(
        'Unexpected entry ${entity.path} in ${fromDir.path}; expected one '
        'directory per target (${known.keys.join(', ')}).',
      );
    }
    final files = entity.listSync();
    if (files.length != 1 ||
        files.single is! File ||
        p.basename(files.single.path) != target.fileName) {
      throw StageException(
        '${entity.path} must hold exactly ${target.fileName}, found '
        '${files.map((f) => p.basename(f.path)).join(', ')}',
      );
    }
    libraries[target.key] = files.single as File;
  }
  final missing = [
    for (final target in targets)
      if (!libraries.containsKey(target.key)) target.name,
  ];
  if (missing.isNotEmpty && !allowPartial) {
    throw StageException(
      'Only ${libraries.length} of $libraryCount libraries; missing '
      '${missing.join(', ')}. (--allow-partial is for local testing only.)',
    );
  }
  if (libraries.isEmpty) {
    throw StageException('No libraries found in ${fromDir.path}');
  }
  return libraries;
}

/// The git-tracked files below [dir], relative to it, `/`-separated.
Future<List<String>> _gitFiles(Directory dir) async {
  final result = await Process.run('git', [
    'ls-files',
    '-z',
  ], workingDirectory: dir.path);
  if (result.exitCode != 0) {
    throw StageException(
      'git ls-files in ${dir.path} failed: ${result.stderr}',
    );
  }
  return [
    for (final file in (result.stdout as String).split('\u0000'))
      if (file.isNotEmpty) file,
  ];
}

void _copy(File from, File to) {
  if (!from.existsSync()) {
    throw StageException(
      '${from.path} is tracked by git but missing; commit or restore it.',
    );
  }
  to.parent.createSync(recursive: true);
  from.copySync(to.path);
}

/// Checks that the sources about to be staged are those of the release [tag]
/// (`frustbite-v<version>`): the libraries come from the tag, the Dart and Rust
/// sources from the working tree, and the two must agree.
///
/// [head] and [tagCommit] are `git rev-parse HEAD` and
/// `git rev-parse <tag>^{commit}` (null when the tag does not exist locally),
/// [porcelain] is `git status --porcelain -- packages/frustbite native`.
void checkReleaseSource({
  required String tag,
  required String? head,
  required String? tagCommit,
  required String porcelain,
  required String pubspecVersion,
}) {
  if (tag != 'frustbite-v$pubspecVersion') {
    throw StageException(
      'The tag $tag does not match the pubspec version $pubspecVersion '
      '(expected frustbite-v$pubspecVersion).',
    );
  }
  if (tagCommit == null) {
    throw StageException(
      'The tag $tag does not exist locally. Run `git fetch --tags`.',
    );
  }
  if (head != tagCommit) {
    throw StageException(
      'HEAD ($head) is not the commit of $tag ($tagCommit). The staged '
      'sources must be the released ones: `git checkout $tag` first.',
    );
  }
  if (porcelain.trim().isNotEmpty) {
    throw StageException(
      'packages/frustbite or native has uncommitted changes, which would be '
      'staged next to the released libraries:\n${porcelain.trim()}',
    );
  }
}

/// Runs [checkReleaseSource] with the real git state of [packageDir].
Future<void> verifyReleaseSource(String tag, Directory packageDir) async {
  Future<String?> git(List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: packageDir.path,
    );
    return result.exitCode == 0 ? (result.stdout as String).trim() : null;
  }

  final root = packageDir.parent.parent.path;
  final porcelain = await git([
    'status',
    '--porcelain',
    '--',
    p.join(root, 'packages/frustbite'),
    p.join(root, 'native'),
  ]);
  if (porcelain == null) {
    throw StageException('git status failed in ${packageDir.path}');
  }
  checkReleaseSource(
    tag: tag,
    head: await git(['rev-parse', 'HEAD']),
    tagCommit: await git(['rev-parse', '$tag^{commit}']),
    porcelain: porcelain,
    pubspecVersion: pubspecVersion(
      File(p.join(packageDir.path, 'pubspec.yaml')).readAsStringSync(),
    ),
  );
}

/// The `version:` of a pubspec text.
String pubspecVersion(String pubspec) {
  final match = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) throw StageException('pubspec.yaml has no version');
  return match.group(1)!;
}

/// `owner/name` of the GitHub repository in a pubspec's `repository:` URL.
String githubRepo(String pubspec) {
  final match = RegExp(
    r'^repository:\s*https://github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?/?\s*$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) {
    throw StageException('pubspec.yaml `repository:` is not a GitHub URL');
  }
  return match.group(1)!;
}

/// Downloads the libraries of the GitHub release [tag] of [repo]
/// (`owner/name`) with `gh` into [into] as a `<target>/<file>` tree and checks
/// them against the release's `checksums.json`. Returns the directory to pass
/// as `fromDir`.
Future<Directory> downloadRelease(
  String tag,
  Directory into, {
  required String repo,
  required bool allowPartial,
}) async {
  final download = Directory(p.join(into.path, 'assets'))
    ..createSync(recursive: true);
  final result = await Process.run('gh', [
    'release',
    'download',
    tag,
    '--repo',
    repo,
    '--dir',
    download.path,
    for (final target in stageTargets) ...['--pattern', target.releaseAsset],
    '--pattern',
    'checksums.json',
  ]);
  if (result.exitCode != 0) {
    throw StageException(
      'gh release download $tag failed (${result.exitCode}): ${result.stderr}',
    );
  }
  return unflattenRelease(
    tag,
    download,
    Directory(p.join(into.path, 'tree')),
    allowPartial: allowPartial,
  );
}

/// Turns the flattened release assets in [assets] into the `<target>/<file>`
/// tree [tree] and checks every library against the `checksums.json` among
/// them. Returns [tree].
Directory unflattenRelease(
  String tag,
  Directory assets,
  Directory tree, {
  required bool allowPartial,
}) {
  final found = <String, String>{};
  for (final target in stageTargets) {
    final asset = File(p.join(assets.path, target.releaseAsset));
    if (!asset.existsSync()) {
      if (allowPartial) continue;
      throw StageException('Release $tag has no ${target.releaseAsset}');
    }
    final to = File(p.join(tree.path, target.name, target.fileName));
    _copy(asset, to);
    found[target.key] = sha256.convert(to.readAsBytesSync()).toString();
  }
  final sums = File(p.join(assets.path, 'checksums.json'));
  if (!sums.existsSync()) {
    throw StageException('Release $tag has no checksums.json');
  }
  final Object? published = jsonDecode(sums.readAsStringSync());
  if (published is! Map<String, Object?>) {
    throw StageException('checksums.json of release $tag is not an object');
  }
  for (final entry in found.entries) {
    if (published[entry.key] != entry.value) {
      throw StageException(
        'Release $tag: ${entry.key} does not match its checksums.json entry '
        '(downloaded ${entry.value}, published ${published[entry.key]})',
      );
    }
  }
  final extra = published.keys.toSet().difference(found.keys.toSet());
  if (extra.isNotEmpty && !allowPartial) {
    throw StageException(
      'Release $tag: checksums.json lists ${extra.join(', ')} with no asset',
    );
  }
  return tree;
}

Future<void> main(List<String> args) async {
  String? fromDir;
  String? fromRelease;
  String? out;
  var allowPartial = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--from-dir':
        fromDir = i + 1 < args.length ? args[++i] : null;
      case '--from-release':
        fromRelease = i + 1 < args.length ? args[++i] : null;
      case '--out':
        out = i + 1 < args.length ? args[++i] : null;
      case '--allow-partial':
        allowPartial = true;
      default:
        _usage('Unknown argument ${args[i]}');
    }
  }
  if (out == null || (fromDir == null) == (fromRelease == null)) {
    _usage('Give --out and exactly one of --from-dir, --from-release.');
  }

  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:frustbite/frustbite.dart'),
  );
  final packageDir = File.fromUri(lib!).parent.parent;
  Directory? scratch;
  try {
    final Directory source;
    if (fromRelease != null) {
      await verifyReleaseSource(fromRelease, packageDir);
      scratch = await Directory.systemTemp.createTemp('frustbite_release_');
      source = await downloadRelease(
        fromRelease,
        scratch,
        repo: githubRepo(
          File(p.join(packageDir.path, 'pubspec.yaml')).readAsStringSync(),
        ),
        allowPartial: allowPartial,
      );
    } else {
      source = Directory(fromDir!);
    }
    final checksums = await stagePackage(
      packageDir: packageDir,
      fromDir: source,
      out: Directory(out),
      allowPartial: allowPartial,
    );
    stdout.writeln(
      'Staged frustbite in $out: ${checksums.length} of $libraryCount '
      'libraries.',
    );
  } on StageException catch (e) {
    stderr.writeln('stage_package: $e');
    exitCode = 1;
  } finally {
    await scratch?.delete(recursive: true);
  }
}

Never _usage(String problem) {
  stderr
    ..writeln(problem)
    ..writeln(
      'Usage: dart tool/stage_package.dart '
      '(--from-dir <dir> | --from-release <tag>) --out <dir> '
      '[--allow-partial]',
    );
  exit(64);
}
