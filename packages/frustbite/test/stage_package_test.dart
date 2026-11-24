@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/check_pubignore.dart';
import '../tool/stage_package.dart';

void main() {
  final packageDir = Directory.current.absolute;
  late Directory scratch;

  setUp(
    () => scratch = Directory.systemTemp.createTempSync('frustbite_stage_'),
  );
  tearDown(() => scratch.deleteSync(recursive: true));

  /// A `tool/build.dart` output dir with a dummy file per target, minus
  /// [skip] targets.
  Directory fakeBuild({Set<String> skip = const {}}) {
    final dir = Directory(p.join(scratch.path, 'libs'));
    for (final target in stageTargets) {
      if (skip.contains(target.name)) continue;
      File(p.join(dir.path, target.name, target.fileName))
        ..createSync(recursive: true)
        ..writeAsStringSync('dummy ${target.name}');
    }
    return dir;
  }

  Future<Map<String, String>> stage(Directory from, {bool partial = false}) =>
      stagePackage(
        packageDir: packageDir,
        fromDir: from,
        out: Directory(p.join(scratch.path, 'staged')),
        allowPartial: partial,
      );

  String staged(String path) => p.join(scratch.path, 'staged', path);

  test('12 libraries give the prebuilt layout and checksums', () async {
    final checksums = await stage(fakeBuild());
    expect(checksums, hasLength(12));

    const expected = {
      'android-arm/libfrustbite.so',
      'android-arm64/libfrustbite.so',
      'android-x64/libfrustbite.so',
      'ios-arm64/libfrustbite.dylib',
      'ios-arm64-sim/libfrustbite.dylib',
      'ios-x64-sim/libfrustbite.dylib',
      'linux-arm64/libfrustbite.so',
      'linux-x64/libfrustbite.so',
      'macos-arm64/libfrustbite.dylib',
      'macos-x64/libfrustbite.dylib',
      'windows-arm64/frustbite.dll',
      'windows-x64/frustbite.dll',
    };
    final json =
        jsonDecode(File(staged('prebuilt/checksums.json')).readAsStringSync())
            as Map<String, Object?>;
    expect(json.keys.toList(), expected.toList()..sort());
    for (final key in expected) {
      expect(File(staged('prebuilt/$key')).existsSync(), isTrue, reason: key);
    }
    expect(
      json['macos-arm64/libfrustbite.dylib'],
      sha256.convert(utf8.encode('dummy macos_arm64')).toString(),
    );
  });

  test('11 libraries fail, and nothing is written', () async {
    await expectLater(
      stage(fakeBuild(skip: {'linux_aarch64'})),
      throwsA(
        isA<StageException>().having(
          (e) => e.message,
          'message',
          allOf(contains('11 of 12'), contains('linux_aarch64')),
        ),
      ),
    );
    expect(Directory(staged('')).existsSync(), isFalse);
  });

  test('--allow-partial accepts a subset', () async {
    final checksums = await stage(
      fakeBuild(skip: {for (final t in stageTargets.skip(2)) t.name}),
      partial: true,
    );
    expect(checksums, hasLength(2));
  });

  test('an unexpected file in the build dir fails', () async {
    final from = fakeBuild();
    File(p.join(from.path, 'macos_arm64', 'extra.txt')).writeAsStringSync('x');
    await expectLater(stage(from), throwsA(isA<StageException>()));
  });

  test('staging inside the repository fails', () async {
    await expectLater(
      stagePackage(
        packageDir: packageDir,
        fromDir: fakeBuild(),
        out: Directory(p.join(packageDir.path, 'staged_inside')),
      ),
      throwsA(isA<StageException>()),
    );
  });

  test('the staged copy holds the crate and no dev files', () async {
    await stage(fakeBuild());

    for (final file in [
      'rust/Cargo.toml',
      'rust/Cargo.lock',
      'rust/build.rs',
      'rust/rust-toolchain.toml',
      'rust/cargo-config.toml',
      'rust/src/lib.rs',
      'pubspec.yaml',
      'hook/build.dart',
      'lib/frustbite.dart',
      'THIRD_PARTY_LICENSES.md',
      'LICENSE',
      '.pubignore',
    ]) {
      expect(File(staged(file)).existsSync(), isTrue, reason: file);
    }
    for (final path in [
      'rust/target',
      'rust/.cargo',
      'rust/tests',
      'rust/tool',
      'rust/RESEARCH.md',
      'rust/cbindgen.toml',
      'test/fixtures',
      'tool',
    ]) {
      expect(
        FileSystemEntity.typeSync(staged(path)),
        FileSystemEntityType.notFound,
        reason: path,
      );
    }
    expect(
      File(staged('pubspec.yaml')).readAsStringSync(),
      isNot(contains('resolution: workspace')),
    );
  });

  test('the staged cargo config keeps only the Windows tables', () async {
    await stage(fakeBuild());
    final config = File(staged('rust/cargo-config.toml')).readAsStringSync();
    expect(config, contains('[target.x86_64-pc-windows-msvc]'));
    expect(config, contains('[target.aarch64-pc-windows-msvc]'));
    expect(RegExp('\\+crt-static').allMatches(config), hasLength(2));
    expect(config, isNot(contains('linker')));
    expect(config, isNot(contains('linux')));
  });

  group('check_pubignore', () {
    test('passes on the staged copy', () async {
      await stage(fakeBuild());
      expect(checkPubignore(Directory(staged(''))), isEmpty);
    });

    test(
      'fails when prebuilt/ or rust/ is excluded, or target/ is not',
      () async {
        await stage(fakeBuild());
        final pubignore = File(staged('.pubignore'));
        final good = pubignore.readAsStringSync();

        pubignore.writeAsStringSync('$good\nprebuilt/\n');
        expect(
          checkPubignore(Directory(staged(''))),
          contains(contains('excludes prebuilt/')),
        );

        pubignore.writeAsStringSync('$good\n/rust\n');
        expect(
          checkPubignore(Directory(staged(''))),
          contains(contains('excludes rust/')),
        );

        pubignore.writeAsStringSync('$good\n*.dylib\n');
        expect(checkPubignore(Directory(staged(''))), isNotEmpty);

        pubignore.writeAsStringSync(
          good.replaceAll('target/', '').replaceAll('test/fixtures/', ''),
        );
        expect(
          checkPubignore(Directory(staged(''))),
          containsAll([contains('rust/target/'), contains('test/fixtures/')]),
        );

        pubignore.writeAsStringSync(good);
        File(staged('rust/.cargo/config.toml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('');
        expect(
          checkPubignore(Directory(staged(''))),
          contains(contains('is hidden')),
        );
        Directory(staged('rust/.cargo')).deleteSync(recursive: true);
        File(staged('rust/cargo-config.toml')).deleteSync();
        expect(
          checkPubignore(Directory(staged(''))),
          contains(contains('rust/cargo-config.toml is missing')),
        );

        pubignore.deleteSync();
        expect(
          checkPubignore(Directory(staged(''))),
          contains(contains('no .pubignore')),
        );
      },
    );

    test('a later negation re-includes', () {
      final rules = PubIgnore(['build/', '!build/keep/', 'a/*.txt']);
      expect(rules.ignores('build/x'), isTrue);
      expect(rules.ignores('a/b.txt'), isTrue);
      expect(rules.ignores('a/b/c.txt'), isFalse);
      expect(rules.ignores('src/build'), isFalse); // `build/` is dir-only
    });
  });
}
