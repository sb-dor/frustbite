// Adapted from hawkkiller/pixer (MIT, Copyright (c) 2026 Michael Lazebny):
// https://github.com/hawkkiller/pixer

import 'dart:async';
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
///
/// A file already at the target path whose sha256 matches is reused without
/// any network access. The connection attempt fails after [connectTimeout],
/// and the transfer fails when no data arrives for [idleTimeout]; both
/// surface as an [HttpException] naming the URL.
Future<File> downloadAsset({
  required OS targetOS,
  required Architecture targetArchitecture,
  required IOSSdk? iOSSdk,
  required Directory outputDirectory,
  Uri Function(String fileName) uriFor = downloadUri,
  Map<String, String> hashes = assetHashes,
  Duration connectTimeout = const Duration(seconds: 30),
  Duration idleTimeout = const Duration(seconds: 60),
}) async {
  final fileName = assetFileName(targetOS, targetArchitecture, iOSSdk);
  final expectedHash = _expectedHash(fileName, hashes);

  final library = File.fromUri(outputDirectory.uri.resolve(fileName));
  if (library.existsSync() && await hashAsset(library) == expectedHash) {
    return library;
  }

  final client = HttpClient()..connectionTimeout = connectTimeout;
  final uri = uriFor(fileName);
  try {
    if (uri.scheme != 'https' && !_isLoopback(uri.host)) {
      throw ArgumentError.value(
        uri,
        'uri',
        'Assets must be fetched over https',
      );
    }
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(idleTimeout);

    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Downloading $uri failed with HTTP ${response.statusCode}',
        uri: uri,
      );
    }

    final partial = File('${library.path}.part');
    await partial.create(recursive: true);
    try {
      await response.timeout(idleTimeout).pipe(partial.openWrite());
      if (library.existsSync()) library.deleteSync();
      await partial.rename(library.path);
    } catch (_) {
      if (partial.existsSync()) partial.deleteSync();
      rethrow;
    }
    return library;
  } on TimeoutException {
    throw HttpException(
      'Downloading $uri timed out: no data for ${idleTimeout.inSeconds} s',
      uri: uri,
    );
  } on SocketException catch (e) {
    // Connection failures, including the connect timeout, name the URL.
    throw HttpException('Downloading $uri failed: ${e.message}', uri: uri);
  } finally {
    client.close(force: true);
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
