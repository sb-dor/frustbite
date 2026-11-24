// Provides the native library of frustbite as a code asset.
//
// Where the library comes from, in order (user defines go in the app's
// pubspec.yaml under `hooks: user_defines: frustbite:`):
//
// 1. `library: <path>`: that file, as is. It must exist.
// 2. `source`, one of (default `auto`; also a per-OS map such as
//    `{default: prebuilt, linux: build}`):
//    - `none`: no asset. The app then fails at its first frustbite call with
//      the existing missing-library / ABI-mismatch load error.
//    - `prebuilt`: the library bundled in the package under
//      `prebuilt/<os>-<arch>[-sim]/`, verified against
//      `prebuilt/checksums.json`. An error if there is none.
//    - `build`: `cargo build` of the Rust crate (`rust/` in the published
//      package, `../../native/` in a checkout or git dependency).
//    - `auto`: the bundled library if present, else cargo if the crate is
//      there and cargo works, else a StateError that lists the options.
// 3. `formats: [mp3, opus, ...]` implies `source: build`: the prebuilt
//    library has every codec.
// 4. `local_build: true` is an alias for `source: build`.
//
// Environment variables are not visible to hooks, so overrides go through
// user defines. The resolution design follows PlugFox/ws (MIT,
// https://github.com/PlugFox/ws, `native/hook/build.dart`); the code is
// written for frustbite. Pixer-derived parts live in `lib/src/hook/`
// (hawkkiller/pixer, MIT, Copyright (c) 2026 Michael Lazebny:
// https://github.com/hawkkiller/pixer).

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:frustbite/src/hook/local_build.dart';
import 'package:frustbite/src/hook/resolve.dart';
import 'package:hooks/hooks.dart';

const _assetName = 'src/bindings/bindings.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // A web build requests no code assets at all; reading `config.code` there
    // would throw, so bail out first.
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;

    final formats = readFormats(input);
    final source = parseSource(
      input.userDefines['source'],
      code.targetOS,
      localBuild: input.userDefines['local_build'] as bool? ?? false,
      hasFormats: formats != null,
    );
    final fileName = libraryFileName(code.targetOS);
    final target = prebuiltDirName(
      code.targetOS,
      code.targetArchitecture,
      iOSSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
    );
    final crateDir = findCrateDir(input.packageRoot);

    // Registered on every path, also when nothing is built, so edits rerun
    // the hook. Only existing files (see hookDependencies).
    output.dependencies.addAll(
      hookDependencies(
        packageRoot: input.packageRoot,
        crateDir: crateDir,
        prebuiltDir: target,
        fileName: fileName,
      ),
    );

    Uri? library = input.userDefines.path('library');
    if (library != null) {
      if (!File.fromUri(library).existsSync()) {
        throw ArgumentError(
          'frustbite: user-define `library` points at $library, which does '
          'not exist',
        );
      }
      output.dependencies.add(library);
    } else if (source != Source.none) {
      library = await _resolve(
        input,
        source,
        target: target,
        fileName: fileName,
        crateDir: crateDir,
        formats: formats,
      );
    }
    // `source: none` (and nothing else) ends here without an asset.
    if (library == null) return;

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );
  });
}

Future<Uri> _resolve(
  BuildInput input,
  Source source, {
  required String target,
  required String fileName,
  required Directory? crateDir,
  required List<String>? formats,
}) async {
  if (source == Source.prebuilt || source == Source.auto) {
    final bundled = File.fromUri(
      input.packageRoot.resolve('prebuilt/$target/$fileName'),
    );
    if (bundled.existsSync()) {
      await verifyPrebuilt(
        bundled,
        checksums: File.fromUri(
          input.packageRoot.resolve('prebuilt/checksums.json'),
        ),
        key: '$target/$fileName',
      );
      return bundled.uri;
    }
    if (source == Source.prebuilt) {
      throw StateError(
        noLibraryMessage(
          target,
          reason:
              '`source: prebuilt` but the package has no prebuilt/$target/'
              '$fileName; only the package published on pub.dev bundles it',
        ),
      );
    }
  }

  // `build`, or `auto` without a bundled library.
  if (crateDir == null) {
    throw StateError(
      noLibraryMessage(
        target,
        reason:
            'no bundled library and no Rust crate (looked for rust/Cargo.toml '
            'in the package and ../../native/Cargo.toml)',
      ),
    );
  }
  try {
    return await cargoBuild(input, crateDir, formats: formats);
  } on CargoBuildException catch (e) {
    // `build` asked for cargo, so its failure is reported as is; in `auto`
    // there is nothing left to try, so explain the options too.
    if (source == Source.build) {
      throw StateError('frustbite: building from source failed: $e');
    }
    throw StateError(
      noLibraryMessage(target, reason: 'no bundled library, and $e'),
    );
  }
}
