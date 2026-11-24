import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:frustbite/src/hook/local_build.dart';
import 'package:frustbite/src/hook/resolve.dart';
import 'package:frustbite/src/hook/targets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

BuildInput _inputWith(Map<String, Object?> defines) {
  final root = Directory.systemTemp.createTempSync('frustbite_hook_test_');
  addTearDown(() => root.deleteSync(recursive: true));
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: root.uri,
      packageName: 'frustbite',
      outputFile: root.uri.resolve('output.json'),
      outputDirectoryShared: root.uri.resolve('shared/'),
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: defines,
          basePath: root.uri,
        ),
      ),
    )
    ..config.setupBuild(linkingEnabled: false);
  return builder.build();
}

Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

void main() {
  group('parseSource', () {
    test('defaults to auto', () {
      expect(parseSource(null, OS.linux), Source.auto);
    });

    test('accepts every source as a string', () {
      for (final source in Source.values) {
        expect(parseSource(source.name, OS.macOS), source);
      }
    });

    test('rejects an unknown value naming the valid ones', () {
      expect(
        () => parseSource('download', OS.linux),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('download'),
              contains('auto, prebuilt, build, none'),
            ),
          ),
        ),
      );
      expect(() => parseSource(true, OS.linux), throwsArgumentError);
    });

    test('a per-OS map picks the OS, then default, then auto', () {
      const map = {'default': 'prebuilt', 'linux': 'build'};
      expect(parseSource(map, OS.linux), Source.build);
      expect(parseSource(map, OS.windows), Source.prebuilt);
      expect(parseSource({'linux': 'none'}, OS.macOS), Source.auto);
    });

    test('a per-OS map rejects an unknown value', () {
      expect(
        () => parseSource({'linux': 'nope'}, OS.linux),
        throwsArgumentError,
      );
    });

    test('local_build: true is an alias for build', () {
      expect(parseSource(null, OS.linux, localBuild: true), Source.build);
      expect(parseSource(null, OS.linux, localBuild: false), Source.auto);
      expect(parseSource('build', OS.linux, localBuild: true), Source.build);
    });

    test('local_build: true conflicts with another explicit source', () {
      expect(
        () => parseSource('prebuilt', OS.linux, localBuild: true),
        throwsArgumentError,
      );
    });

    test('formats implies build', () {
      expect(parseSource(null, OS.linux, hasFormats: true), Source.build);
      expect(parseSource('auto', OS.linux, hasFormats: true), Source.build);
      expect(parseSource('build', OS.linux, hasFormats: true), Source.build);
    });

    test('formats cannot come from the prebuilt library', () {
      expect(
        () => parseSource('prebuilt', OS.linux, hasFormats: true),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('formats'),
          ),
        ),
      );
    });

    test('formats with none stays none', () {
      expect(parseSource('none', OS.linux, hasFormats: true), Source.none);
    });
  });

  group('prebuilt directory names', () {
    test('all 12 targets map to os-arch[-sim] names', () {
      final names = {
        for (final (os, arch, sdk) in supportedTargets)
          prebuiltDirName(os, arch, iOSSdk: sdk),
      };
      expect(names, {
        'android-arm',
        'android-arm64',
        'android-x64',
        'ios-arm64',
        'ios-arm64-sim',
        'ios-x64-sim',
        'linux-arm64',
        'linux-x64',
        'macos-arm64',
        'macos-x64',
        'windows-arm64',
        'windows-x64',
      });
    });

    test('maps the release target names of tool/build.dart', () {
      expect(prebuiltDirForTargetName('macos_arm64'), 'macos-arm64');
      expect(prebuiltDirForTargetName('macos_x86_64'), 'macos-x64');
      expect(prebuiltDirForTargetName('android_armv7'), 'android-arm');
      expect(prebuiltDirForTargetName('ios_sim_arm64'), 'ios-arm64-sim');
      expect(prebuiltDirForTargetName('linux_aarch64'), 'linux-arm64');
      expect(prebuiltDirForTargetName('windows_x86_64'), 'windows-x64');
    });

    test('the mapping covers every target and is one to one', () {
      final dirs = {
        for (final (os, arch, sdk) in supportedTargets)
          prebuiltDirForTargetName(getNameForTarget(os, arch, sdk)),
      };
      expect(dirs, hasLength(12));
    });

    test('an unknown release target name throws', () {
      expect(() => prebuiltDirForTargetName('plan9_mips'), throwsArgumentError);
    });
  });

  test('one library file name per OS', () {
    expect(libraryFileName(OS.linux), 'libfrustbite.so');
    expect(libraryFileName(OS.android), 'libfrustbite.so');
    expect(libraryFileName(OS.macOS), 'libfrustbite.dylib');
    expect(libraryFileName(OS.iOS), 'libfrustbite.dylib');
    expect(libraryFileName(OS.windows), 'frustbite.dll');
  });

  test('rustTriple covers all 12 targets', () {
    final triples = {
      for (final (os, arch, sdk) in supportedTargets)
        rustTriple(os, arch, iOSSdk: sdk),
    };
    expect(triples, {
      'armv7-linux-androideabi',
      'aarch64-linux-android',
      'x86_64-linux-android',
      'aarch64-apple-ios',
      'aarch64-apple-ios-sim',
      'x86_64-apple-ios',
      'aarch64-unknown-linux-gnu',
      'x86_64-unknown-linux-gnu',
      'aarch64-apple-darwin',
      'x86_64-apple-darwin',
      'aarch64-pc-windows-msvc',
      'x86_64-pc-windows-msvc',
    });
  });

  group('checksum check', () {
    late Directory prebuilt;
    final bytes = utf8.encode('pretend dylib bytes');
    final digest = sha256.convert(bytes).toString();
    const dir = 'macos-arm64';
    const name = 'libfrustbite.dylib';

    File library() => File('${prebuilt.path}/$dir/$name');
    File sums() => File('${prebuilt.path}/checksums.json');

    setUp(() {
      prebuilt = _tempDir('frustbite_prebuilt_');
      library()
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    });

    test('a matching checksum passes', () async {
      sums().writeAsStringSync(jsonEncode({'$dir/$name': digest}));
      await verifyPrebuilt(library(), checksums: sums(), key: '$dir/$name');
    });

    test('a mismatch throws and mentions corruption', () async {
      sums().writeAsStringSync(jsonEncode({'$dir/$name': digest}));
      library().writeAsBytesSync([...bytes, 0]);
      await expectLater(
        verifyPrebuilt(library(), checksums: sums(), key: '$dir/$name'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('checksum mismatch'),
              contains('corrupt'),
              contains('$dir/$name'),
            ),
          ),
        ),
      );
    });

    test('a missing checksums.json is an error, not a skipped check', () async {
      await expectLater(
        verifyPrebuilt(library(), checksums: sums(), key: '$dir/$name'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('checksums.json is missing'),
          ),
        ),
      );
    });

    test('a checksums.json without the file is an error', () async {
      sums().writeAsStringSync(jsonEncode({'linux-x64/libfrustbite.so': 'ab'}));
      await expectLater(
        verifyPrebuilt(library(), checksums: sums(), key: '$dir/$name'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no checksum'),
          ),
        ),
      );
    });

    test('a malformed checksums.json is an error', () async {
      sums().writeAsStringSync('[1, 2]');
      await expectLater(
        verifyPrebuilt(library(), checksums: sums(), key: '$dir/$name'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('findCrateDir', () {
    test('prefers rust/ in the package over ../../native/', () {
      final root = _tempDir('frustbite_crate_');
      final package = Directory('${root.path}/packages/frustbite')
        ..createSync(recursive: true);
      Directory('${package.path}/rust').createSync();
      File('${package.path}/rust/Cargo.toml').writeAsStringSync('');
      Directory('${root.path}/native').createSync();
      File('${root.path}/native/Cargo.toml').writeAsStringSync('');
      final dir = findCrateDir(package.uri);
      expect(dir, isNotNull);
      expect(
        FileSystemEntity.identicalSync(dir!.path, '${package.path}/rust'),
        isTrue,
      );
    });

    test('falls back to ../../native/', () {
      final root = _tempDir('frustbite_crate_');
      final package = Directory('${root.path}/packages/frustbite')
        ..createSync(recursive: true);
      Directory('${root.path}/native').createSync();
      File('${root.path}/native/Cargo.toml').writeAsStringSync('');
      final dir = findCrateDir(package.uri);
      expect(dir, isNotNull);
      expect(
        FileSystemEntity.identicalSync(dir!.path, '${root.path}/native'),
        isTrue,
      );
    });

    test('a directory without Cargo.toml does not count', () {
      final root = _tempDir('frustbite_crate_');
      final package = Directory('${root.path}/packages/frustbite')
        ..createSync(recursive: true);
      Directory('${package.path}/rust').createSync();
      expect(findCrateDir(package.uri), isNull);
    });

    test('returns null when there is no crate', () {
      final root = _tempDir('frustbite_nocrate_');
      final package = Directory('${root.path}/packages/frustbite')
        ..createSync(recursive: true);
      expect(findCrateDir(package.uri), isNull);
    });
  });

  group('cargoTargetKey', () {
    test('includes the NDK API on Android', () {
      expect(cargoTargetKey(OS.android, androidNdkApi: 30), 'android-30');
      expect(
        cargoTargetKey(OS.android, androidNdkApi: 30),
        isNot(cargoTargetKey(OS.android, androidNdkApi: 24)),
      );
    });

    test('includes the deployment version on Apple platforms', () {
      expect(
        cargoTargetKey(OS.macOS, appleVersion: AppleVersion(13)),
        'macos-13.0',
      );
      expect(
        cargoTargetKey(OS.iOS, appleVersion: AppleVersion(16, minor: 4)),
        'ios-16.4',
      );
      expect(
        cargoTargetKey(OS.macOS, appleVersion: AppleVersion(13)),
        isNot(cargoTargetKey(OS.macOS, appleVersion: AppleVersion(14))),
      );
    });

    test('is a single fixed key elsewhere', () {
      expect(cargoTargetKey(OS.linux), 'default');
      expect(cargoTargetKey(OS.windows), 'default');
    });

    test('requires the version where it matters', () {
      expect(() => cargoTargetKey(OS.android), throwsArgumentError);
      expect(() => cargoTargetKey(OS.macOS), throwsArgumentError);
    });
  });

  test('ndkClang names the wrapper, a .cmd on Windows hosts', () {
    expect(
      ndkClang('aarch64-linux-android', 30, windows: false),
      'aarch64-linux-android30-clang',
    );
    expect(
      ndkClang('armv7a-linux-androideabi', 30, windows: true),
      'armv7a-linux-androideabi30-clang.cmd',
    );
  });

  test('ndkTriplePrefix maps armv7 to armv7a', () {
    expect(
      ndkTriplePrefix('armv7-linux-androideabi'),
      'armv7a-linux-androideabi',
    );
    expect(ndkTriplePrefix('aarch64-linux-android'), 'aarch64-linux-android');
  });

  group('existingFiles', () {
    test('keeps only files that exist', () {
      final dir = _tempDir('frustbite_deps_');
      final present = File('${dir.path}/Cargo.toml')..writeAsStringSync('');
      final missing = File('${dir.path}/checksums.json');
      Directory('${dir.path}/subdir').createSync();
      final kept = existingFiles([
        present.uri,
        missing.uri,
        Uri.directory('${dir.path}/subdir'),
      ]);
      expect(kept, [present.uri]);
    });
  });

  group('hookDependencies', () {
    test(
      'lists crate sources and the prebuilt file, only those that exist',
      () {
        final root = _tempDir('frustbite_deps_');
        final package = Directory('${root.path}/pkg')..createSync();
        final crate = Directory('${package.path}/rust')..createSync();
        File('${crate.path}/Cargo.toml').writeAsStringSync('');
        File('${crate.path}/Cargo.lock').writeAsStringSync('');
        Directory('${crate.path}/src/nested').createSync(recursive: true);
        File('${crate.path}/src/lib.rs').writeAsStringSync('');
        File('${crate.path}/src/nested/mod.rs').writeAsStringSync('');
        File('${crate.path}/src/notes.txt').writeAsStringSync('');
        final prebuiltFile = File(
          '${package.path}/prebuilt/macos-arm64/x.dylib',
        )..createSync(recursive: true);
        final deps = hookDependencies(
          packageRoot: package.uri,
          crateDir: crate,
          prebuiltDir: 'macos-arm64',
          fileName: 'x.dylib',
        );
        expect(deps.every((uri) => File.fromUri(uri).existsSync()), isTrue);
        final paths = deps.map((uri) => uri.toFilePath()).toList();
        expect(paths, hasLength(5));
        expect(paths.any((p) => p.endsWith('Cargo.toml')), isTrue);
        expect(paths.any((p) => p.endsWith('Cargo.lock')), isTrue);
        expect(paths.any((p) => p.endsWith('lib.rs')), isTrue);
        expect(paths.any((p) => p.endsWith('mod.rs')), isTrue);
        expect(deps, contains(prebuiltFile.uri));
        expect(paths.any((p) => p.endsWith('notes.txt')), isFalse);
      },
    );

    test('adds the prebuilt file and checksums.json when present', () {
      final root = _tempDir('frustbite_deps_');
      final package = Directory('${root.path}/pkg')..createSync();
      final prebuiltFile = File('${package.path}/prebuilt/macos-arm64/x.dylib')
        ..createSync(recursive: true);
      final sums = File('${package.path}/prebuilt/checksums.json')
        ..writeAsStringSync('{}');
      final deps = hookDependencies(
        packageRoot: package.uri,
        crateDir: null,
        prebuiltDir: 'macos-arm64',
        fileName: 'x.dylib',
      );
      expect(deps, unorderedEquals([prebuiltFile.uri, sums.uri]));
    });

    test('is empty when nothing exists', () {
      final root = _tempDir('frustbite_deps_');
      expect(
        hookDependencies(
          packageRoot: root.uri,
          crateDir: null,
          prebuiltDir: 'linux-x64',
          fileName: 'libfrustbite.so',
        ),
        isEmpty,
      );
    });
  });

  group('noLibraryMessage', () {
    test('names the target and the three ways out', () {
      final message = noLibraryMessage(
        'android-arm',
        reason: 'cargo is not installed',
      );
      expect(message, contains('android-arm'));
      expect(message, contains('cargo is not installed'));
      expect(message, contains('source: prebuilt'));
      expect(message, contains('source: build'));
      expect(message, contains('library:'));
    });
  });

  group('readFormats', () {
    test('accepts ["mp3","OPUS"] and normalises', () {
      expect(
        readFormats(
          _inputWith({
            'formats': ['mp3', 'OPUS'],
          }),
        ),
        ['mp3', 'opus'],
      );
    });

    test('returns null when unset', () {
      expect(readFormats(_inputWith({})), isNull);
    });

    test('rejects unknown "wma" listing supported formats', () {
      expect(
        () => readFormats(
          _inputWith({
            'formats': ['wma'],
          }),
        ),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('wma'))
              .having((e) => e.message, 'message', contains('Supported: ')),
        ),
      );
    });

    test('rejects empty list', () {
      expect(
        () => readFormats(_inputWith({'formats': <String>[]})),
        throwsFormatException,
      );
    });
  });

  test('cargoFeatureArgs selects features', () {
    expect(cargoFeatureArgs(null), isEmpty);
    expect(cargoFeatureArgs(['mp3', 'opus']), [
      '--no-default-features',
      '--features',
      'mp3,opus',
    ]);
  });

  test('appleDeploymentTarget is major.minor', () {
    expect(appleDeploymentTarget(AppleVersion(13)), '13.0');
    expect(appleDeploymentTarget(AppleVersion(10, minor: 15)), '10.15');
  });

  test('the workspace hook defines build from source', () {
    // The root pubspec's `local_build: true` must keep meaning `build`.
    expect(parseSource(null, OS.macOS, localBuild: true), Source.build);
  });
}
