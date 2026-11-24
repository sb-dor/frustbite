import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:frustbite/src/hook/hashes.dart';
import 'package:frustbite/src/hook/targets.dart';
import 'package:frustbite/src/hook/version.dart';

/// The URL of the release asset called [fileName].
Uri downloadUri(String fileName) => Uri.parse(
  'https://github.com/sb-dor/frustbite/releases/download/$version/$fileName',
);

/// The target name of an asset, `frustbite_<target>`, without extension.
String createTargetName(
  OS targetOS,
  Architecture targetArchitecture,
  IOSSdk? iOSSdk,
) => 'frustbite_${getNameForTarget(targetOS, targetArchitecture, iOSSdk)}';

/// The release asset file name, for example `libfrustbite_linux_x86_64.so`.
String assetFileName(
  OS targetOS,
  Architecture targetArchitecture,
  IOSSdk? iOSSdk,
) => targetOS.dylibFileName(
  createTargetName(targetOS, targetArchitecture, iOSSdk),
);

/// Downloads the asset for the given target into [outputDirectory].
///
/// Throws a [StateError] before any network access when [hashes] has no entry
/// for the asset, because it could not be verified. [uriFor] and [hashes]
/// exist for tests; by default the GitHub release and [assetHashes] are used.
Future<File> downloadAsset({
  required OS targetOS,
  required Architecture targetArchitecture,
  required IOSSdk? iOSSdk,
  required Directory outputDirectory,
  Uri Function(String fileName) uriFor = downloadUri,
  Map<String, String> hashes = assetHashes,
}) async {
  final fileName = assetFileName(targetOS, targetArchitecture, iOSSdk);
  _expectedHash(fileName, hashes);

  final client = HttpClient();
  try {
    final uri = uriFor(fileName);
    if (uri.scheme != 'https' && !_isLoopback(uri.host)) {
      throw ArgumentError.value(
        uri,
        'uri',
        'Assets must be fetched over https',
      );
    }
    final request = await client.getUrl(uri);
    final response = await request.close();

    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Downloading $uri failed with HTTP ${response.statusCode}',
        uri: uri,
      );
    }

    final library = File.fromUri(outputDirectory.uri.resolve(fileName));
    final partial = File('${library.path}.part');
    await partial.create(recursive: true);
    try {
      await response.pipe(partial.openWrite());
      await partial.rename(library.path);
    } catch (_) {
      if (partial.existsSync()) partial.deleteSync();
      rethrow;
    }
    return library;
  } finally {
    client.close();
  }
}

/// Checks the sha256 of [asset] against [hashes] (default [assetHashes]).
///
/// Throws, and deletes [asset], when it does not match.
Future<void> verifyAssetHash(
  File asset, {
  required String fileName,
  Map<String, String> hashes = assetHashes,
}) async {
  final expected = _expectedHash(fileName, hashes);
  final actual = await hashAsset(asset);
  if (actual != expected) {
    if (asset.existsSync()) asset.deleteSync();
    throw StateError(
      'Asset hash mismatch for $fileName: expected $expected, got $actual',
    );
  }
}

/// Computes the SHA-256 hash of the given [assetFile].
Future<String> hashAsset(File assetFile) async =>
    sha256.convert(await assetFile.readAsBytes()).toString();

String _expectedHash(String fileName, Map<String, String> hashes) {
  final hash = hashes[fileName];
  if (hash == null) {
    throw StateError(
      'No hash for $fileName; this package version has no prebuilt binaries '
      '— set hooks.user_defines.frustbite.local_build: true',
    );
  }
  return hash;
}

bool _isLoopback(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);
