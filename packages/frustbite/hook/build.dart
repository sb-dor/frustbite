import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:frustbite/src/hook/download_asset.dart';
import 'package:frustbite/src/hook/local_build.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // The code config is only available when the build targets code assets;
    // accessing it throws on web (a plain Exception with no dedicated type or
    // flag in the hooks API to check beforehand), so treat that as "no native
    // assets needed".
    final CodeConfig codeConfig;
    try {
      codeConfig = input.config.code;
    } catch (_) {
      return;
    }

    final formats = readFormats(input);
    // Prebuilt binaries include every format, so a custom set needs a source
    // build.
    final localBuild =
        formats != null || (input.userDefines['local_build'] as bool? ?? false);
    if (localBuild) {
      await runLocalBuild(input, output, formats: formats);
      return;
    }

    final targetOS = codeConfig.targetOS;
    final targetArchitecture = codeConfig.targetArchitecture;
    final iOSSdk = targetOS == OS.iOS ? codeConfig.iOS.targetSdk : null;

    final file = await downloadAsset(
      targetOS: targetOS,
      targetArchitecture: targetArchitecture,
      iOSSdk: iOSSdk,
      outputDirectory: Directory.fromUri(input.outputDirectory),
    );
    await verifyAssetHash(
      file,
      fileName: assetFileName(targetOS, targetArchitecture, iOSSdk),
    );

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/bindings/bindings.dart',
        linkMode: DynamicLoadingBundled(),
        file: file.uri,
      ),
    );
  });
}
