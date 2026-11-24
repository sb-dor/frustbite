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

  group('release assets', () {
    test('the 12 asset names are pinned', () {
      expect(stageTargets.map((t) => t.releaseAsset).toList(), [
        'libfrustbite_android_armv7.so',
        'libfrustbite_android_arm64.so',
        'libfrustbite_android_x86_64.so',
        'libfrustbite_ios_arm64.dylib',
        'libfrustbite_ios_sim_arm64.dylib',
        'libfrustbite_ios_sim_x86_64.dylib',
        'libfrustbite_linux_aarch64.so',
        'libfrustbite_linux_x86_64.so',
        'libfrustbite_macos_arm64.dylib',
        'libfrustbite_macos_x86_64.dylib',
        'frustbite_windows_arm64.dll',
        'frustbite_windows_x86_64.dll',
      ]);
    });

    Directory fakeAssets() {
      final dir = Directory(p.join(scratch.path, 'assets'))..createSync();
      final sums = <String, String>{};
      for (final t in stageTargets) {
        final bytes = utf8.encode('release ${t.name}');
        File(p.join(dir.path, t.releaseAsset)).writeAsBytesSync(bytes);
        sums[t.key] = sha256.convert(bytes).toString();
      }
      File(
        p.join(dir.path, 'checksums.json'),
      ).writeAsStringSync(jsonEncode(sums));
      return dir;
    }

    Directory tree() => Directory(p.join(scratch.path, 'tree'));

    test('un-flattens into the build.dart layout', () async {
      unflattenRelease('t', fakeAssets(), tree(), allowPartial: false);
      final checksums = await stage(tree());
      expect(checksums, hasLength(12));
    });

    test('a mismatching checksum fails', () {
      final dir = fakeAssets();
      File(
        p.join(dir.path, 'libfrustbite_linux_x86_64.so'),
      ).writeAsStringSync('x');
      expect(
        () => unflattenRelease('t', dir, tree(), allowPartial: false),
        throwsA(
          isA<StageException>().having(
            (e) => e.message,
            'message',
            contains('linux-x64/libfrustbite.so does not match'),
          ),
        ),
      );
    });

    test('a checksums.json entry without an asset fails', () {
      final dir = fakeAssets();
      final file = File(p.join(dir.path, 'checksums.json'));
      final sums = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      file.writeAsStringSync(
        jsonEncode({...sums, 'plan9-x64/libfrustbite.so': 'a'}),
      );
      expect(
        () => unflattenRelease('t', dir, tree(), allowPartial: false),
        throwsA(isA<StageException>()),
      );
    });

    test('a missing asset or checksums.json fails', () {
      final dir = fakeAssets();
      File(p.join(dir.path, 'frustbite_windows_arm64.dll')).deleteSync();
      expect(
        () => unflattenRelease('t', dir, tree(), allowPartial: false),
        throwsA(isA<StageException>()),
      );
      File(p.join(dir.path, 'checksums.json')).deleteSync();
      expect(
        () => unflattenRelease('t', dir, tree(), allowPartial: true),
        throwsA(isA<StageException>()),
      );
    });
  });

  group('checkReleaseSource', () {
    void check({
      String tag = 'frustbite-v0.0.2',
      String? head = 'abc',
      String? tagCommit = 'abc',
      String porcelain = '',
      String version = '0.0.2',
    }) => checkReleaseSource(
      tag: tag,
      head: head,
      tagCommit: tagCommit,
      porcelain: porcelain,
      pubspecVersion: version,
    );
    Matcher fails(String text) => throwsA(
      isA<StageException>().having((e) => e.message, 'm', contains(text)),
    );

    test('passes for the clean checkout of the tag', () => check());
    test(
      'HEAD must be the tag commit',
      () => expect(() => check(head: 'def'), fails('is not the commit')),
    );
    test(
      'an unknown tag fails',
      () => expect(() => check(tagCommit: null), fails('does not exist')),
    );
    test(
      'uncommitted changes fail',
      () => expect(
        () => check(porcelain: ' M native/src/ffi.rs\n'),
        fails('uncommitted'),
      ),
    );
    test('the pubspec version must match the tag', () {
      expect(
        () => check(version: '0.0.3'),
        fails('does not match the pubspec'),
      );
      expect(() => check(tag: 'v0.0.2'), fails('does not match the pubspec'));
    });
  });

  test('the repository comes from the pubspec', () {
    expect(
      githubRepo('name: x\nrepository: https://github.com/sb-dor/frustbite\n'),
      'sb-dor/frustbite',
    );
    expect(githubRepo('repository: https://github.com/a/b/\n'), 'a/b');
    expect(() => githubRepo('name: x'), throwsA(isA<StageException>()));
    expect(pubspecVersion('name: x\nversion: 1.2.3\n'), '1.2.3');
  });
}
