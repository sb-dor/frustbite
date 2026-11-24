import 'dart:io';

import 'package:ffigen/ffigen.dart';

/// Enums shared with the web implementation: hidden from the generated
/// bindings and redefined in `lib/src/enums.dart`.
const _sharedEnums = {
  'FrustbiteErrorCode',
  'FrustbiteContainer',
  'FrustbiteCodec',
  'FrustbiteWaveformMode',
};

/// Functions that never call back into Dart and can run as leaf calls. Cheap calls only: no
/// I/O, no decoding.
const _leafSymbols = {
  'frustbite_abi_version',
  'frustbite_source_byte_length',
  'frustbite_free_f32',
  'frustbite_free_bytes',
};

Future<void> main() async {
  final packageDir = File.fromUri(Platform.script).absolute.parent.parent.uri;
  final nativeDir = packageDir.resolve('../../native/');
  final header = nativeDir.resolve('include/frustbite.h');
  final output = packageDir.resolve('lib/src/bindings/bindings.dart');
  final sharedEnums = packageDir.resolve('lib/src/enums.dart');

  _runCbindgen(nativeDir, header);

  final generator = FfiGenerator(
    input: Input(
      entryPoints: [header],
      include: (candidate) => _sameFile(candidate, header),
      compilerOptions: _macOSCompilerOptions(),
    ),
    output: Output(
      dart: DartOutput(path: output),
      preamble: '''
// ignore_for_file: always_specify_types
// ignore_for_file: camel_case_types
// ignore_for_file: non_constant_identifier_names
''',
      commentType: const CommentType(CommentStyle.any, CommentLength.full),
      style: const NativeExternalBindings(
        assetId: 'package:frustbite/src/bindings/bindings.dart',
      ),
    ),
    // Top-level declarations are excluded by default; include all but the shared enums.
    visitors: [
      Visitor(
        func: (node) {
          node.isIncluded = true;
          node.isLeaf = _leafSymbols.contains(node.originalName);
        },
        struct: (node) => node.isIncluded = true,
        union: (node) => node.isIncluded = true,
        enumClass: (node) =>
            node.isIncluded = !_sharedEnums.contains(node.originalName),
        global: (node) => node.isIncluded = true,
        macroConstant: (node) => node.isIncluded = true,
      ),
    ],
  );

  await generator.generate();
  _generateSharedEnums(File.fromUri(header), File.fromUri(sharedEnums));
}

void _runCbindgen(Uri nativeDir, Uri header) {
  final result = Process.runSync('cbindgen', [
    '--config',
    'cbindgen.toml',
    '--crate',
    'frustbite',
    '--output',
    File.fromUri(header).path,
  ], workingDirectory: Directory.fromUri(nativeDir).path);
  if (result.exitCode != 0) {
    throw ProcessException(
      'cbindgen',
      const [],
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
}

void _generateSharedEnums(File headerFile, File output) {
  // Read the shared enums from the header: ffigen is told to skip them.
  final header = headerFile.readAsStringSync();
  final declarations = _sharedEnums
      .map((name) => _dartEnum(header, name))
      .join('\n\n');

  output.writeAsStringSync('''
// AUTO GENERATED FILE, DO NOT EDIT.
//
// Generated from native/include/frustbite.h by tool/generate_bindings.dart.

$declarations
''');
  final format = Process.runSync(Platform.resolvedExecutable, [
    'format',
    output.path,
  ]);
  if (format.exitCode != 0) {
    throw ProcessException(
      'dart',
      ['format', output.path],
      '${format.stdout}${format.stderr}',
      format.exitCode,
    );
  }
}

String _dartEnum(String header, String name) {
  final start = header.indexOf('enum $name\n');
  if (start == -1) throw StateError('$name was not found in the header');
  final open = header.indexOf('{', start);
  final close = header.indexOf('};', open);
  final body = header.substring(open + 1, close);

  final members = RegExp(
    r'(?:/\*\*\s*((?:.|\n)*?)\s*\*/\s*)?(\w+) = (\d+),',
  ).allMatches(body);
  final hasUnknown = RegExp(r'\bUnknown = ').hasMatch(body);
  final orElse = hasUnknown
      ? '() => $name.unknown'
      : "() => throw ArgumentError.value(value, 'value', 'Unknown $name')";
  final buffer = StringBuffer('enum $name {\n');
  final entries = <String>[];
  for (final member in members) {
    final doc = member[1]
        ?.split('\n')
        .map((line) => line.replaceFirst(RegExp(r'^\s*\*?\s*'), ''))
        .join(' ')
        .trim();
    // cbindgen prefixes variants of some enums (`FrustbiteCodec_Mp3`).
    final identifier = member[2]!.replaceFirst('${name}_', '');
    final lowerCamel = identifier[0].toLowerCase() + identifier.substring(1);
    entries.add(
      '${doc == null || doc.isEmpty ? '' : '  /// $doc\n'}  $lowerCamel(${member[3]})',
    );
  }
  buffer
    ..write(entries.join(',\n'))
    ..write(';\n\n  const $name(this.value);\n\n  final int value;\n')
    ..write('\n  static $name fromValue(int value) =>\n')
    ..write(
      '      values.firstWhere((e) => e.value == value, orElse: $orElse);\n',
    )
    ..write('}');
  return buffer.toString();
}

List<String>? _macOSCompilerOptions() {
  if (!Platform.isMacOS) return null;

  final result = Process.runSync('xcrun', [
    '--sdk',
    'macosx',
    '--show-sdk-path',
  ]);
  if (result.exitCode != 0) return null;

  final sdkPath = (result.stdout as String).trim();
  if (sdkPath.isEmpty) return null;

  return ['-isysroot', sdkPath];
}

bool _sameFile(Uri left, Uri right) =>
    _absolutePath(left) == _absolutePath(right);

String _absolutePath(Uri uri) => File.fromUri(uri).absolute.path;
