// Checks the `.pubignore` of a staged package (see tool/stage_package.dart).
//
// A package with a `.pubignore` is published by that file alone: the
// `.gitignore` is no longer read. The repository's `.gitignore` hides
// `prebuilt/` (it is staged, never committed), so a missing or careless
// `.pubignore` would publish a package without its libraries. This checks
// that, in the staged directory:
//   - there is a `.pubignore`;
//   - no file under `prebuilt/` or `rust/` is ignored or hidden (pub leaves
//     dot files and directories out of the archive, whatever the ignore
//     files say);
//   - `rust/target/` (a cargo build dir) and `test/fixtures/` are ignored.
//
//   dart tool/check_pubignore.dart <staged dir>
//
// The check is modelled on PlugFox/ws (MIT, https://github.com/PlugFox/ws,
// tool/check_pubignore.dart), which compares `.gitignore` and `.pubignore`;
// frustbite asserts the published outcome instead. The pattern matching is
// the gitignore subset a `.pubignore` uses here: comments, `!`, a leading `/`,
// a trailing `/`, `*`, `**` and `?`.
import 'dart:io';

import 'package:path/path.dart' as p;

/// The problems of the staged package in [staged]; empty when it is fine.
List<String> checkPubignore(Directory staged) {
  final file = File(p.join(staged.path, '.pubignore'));
  if (!file.existsSync()) {
    return [
      'There is no .pubignore: pub would fall back to the .gitignore, which '
          'hides prebuilt/.',
    ];
  }
  final rules = PubIgnore(file.readAsLinesSync());
  final problems = <String>[];

  for (final dir in ['prebuilt', 'rust']) {
    final root = Directory(p.join(staged.path, dir));
    if (!root.existsSync()) {
      problems.add('$dir/ is missing from the staged package.');
      continue;
    }
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File) continue;
      // `/`-separated whatever the platform: the ignore rules match on that.
      final parts = p.split(p.relative(entity.path, from: staged.path));
      final path = parts.join('/');
      if (parts.any((part) => part.startsWith('.'))) {
        problems.add(
          '$path is hidden: pub leaves hidden files out of the archive.',
        );
      }
      if (rules.ignores(path)) {
        problems.add('.pubignore excludes $path, which must be published.');
      }
    }
  }
  for (final path in ['rust/Cargo.lock', 'rust/cargo-config.toml']) {
    if (!File(p.joinAll([staged.path, ...path.split('/')])).existsSync()) {
      problems.add('$path is missing from the staged package.');
    }
  }
  for (final path in [
    'rust/target/release/libfrustbite.so',
    'rust/target/debug/build/x',
    'test/fixtures/sample.mp3',
    'test/stage_package_test.dart',
  ]) {
    if (!rules.ignores(path)) {
      problems.add('.pubignore does not exclude $path.');
    }
  }
  return problems;
}

/// The ignore rules of a `.pubignore` / `.gitignore` text.
class PubIgnore {
  PubIgnore(Iterable<String> lines) {
    for (final raw in lines) {
      var line = raw.trimRight();
      if (line.isEmpty || line.startsWith('#')) continue;
      final negated = line.startsWith('!');
      if (negated) line = line.substring(1);
      final dirOnly = line.endsWith('/');
      if (dirOnly) line = line.substring(0, line.length - 1);
      // A pattern with a slash (other than the trailing one) is anchored to
      // the root; one without matches at any depth.
      final anchored = line.contains('/');
      if (line.startsWith('/')) line = line.substring(1);
      _rules.add(
        _Rule(
          RegExp('^${anchored ? '' : '(?:.*/)?'}${_glob(line)}\$'),
          negated: negated,
          dirOnly: dirOnly,
        ),
      );
    }
  }

  final _rules = <_Rule>[];

  /// Whether pub leaves the file at [path] (`/`-separated, relative to the
  /// package root) out of the archive: it, or a directory above it, matches.
  bool ignores(String path) {
    final parts = path.split('/');
    for (var i = 1; i <= parts.length; i++) {
      final isDir = i < parts.length;
      final candidate = parts.take(i).join('/');
      var ignored = false;
      for (final rule in _rules) {
        if (rule.dirOnly && !isDir) continue;
        if (rule.pattern.hasMatch(candidate)) ignored = !rule.negated;
      }
      if (ignored) return true;
    }
    return false;
  }
}

class _Rule {
  _Rule(this.pattern, {required this.negated, required this.dirOnly});
  final RegExp pattern;
  final bool negated;
  final bool dirOnly;
}

String _glob(String glob) {
  final out = StringBuffer();
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        i++;
        // `**/` matches zero or more directories; a bare `**` anything.
        if (i + 1 < glob.length && glob[i + 1] == '/') {
          i++;
          out.write('(?:.*/)?');
        } else {
          out.write('.*');
        }
      } else {
        out.write('[^/]*');
      }
    } else if (c == '?') {
      out.write('[^/]');
    } else {
      out.write(RegExp.escape(c));
    }
  }
  return out.toString();
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart tool/check_pubignore.dart <staged dir>');
    exit(64);
  }
  final problems = checkPubignore(Directory(args.single));
  if (problems.isEmpty) {
    stdout.writeln('.pubignore keeps prebuilt/ and rust/, drops rust/target/.');
    return;
  }
  stderr.writeln('check_pubignore:');
  for (final problem in problems) {
    stderr.writeln('  $problem');
  }
  exit(1);
}
