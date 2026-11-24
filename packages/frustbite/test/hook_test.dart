import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:frustbite/src/hook/download_asset.dart';
import 'package:frustbite/src/hook/local_build.dart';
import 'package:frustbite/src/hook/targets.dart';
import 'package:frustbite/src/hook/version.dart';
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

void main() {
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

  group('targets', () {
    test('cover all 12 targets uniquely', () {
      expect(supportedTargets, hasLength(12));
      final names = {
        for (final (os, arch, sdk) in supportedTargets)
          getNameForTarget(os, arch, sdk),
      };
      expect(names, hasLength(12));
      final files = {
        for (final (os, arch, sdk) in supportedTargets)
          assetFileName(os, arch, sdk),
      };
      expect(files, hasLength(12));
    });

    test('file names follow frustbite_<target>.<ext>', () {
      expect(
        assetFileName(OS.linux, Architecture.x64, null),
        'libfrustbite_linux_x86_64.so',
      );
      expect(
        assetFileName(OS.windows, Architecture.arm64, null),
        'frustbite_windows_arm64.dll',
      );
      expect(
        assetFileName(OS.iOS, Architecture.arm64, IOSSdk.iPhoneSimulator),
        'libfrustbite_ios_sim_arm64.dylib',
      );
    });
  });

  test('downloadUri uses sb-dor/frustbite and the version tag', () {
    expect(version, 'frustbite-assets-v0.0.1');
    expect(
      downloadUri('x.so').toString(),
      'https://github.com/sb-dor/frustbite/releases/download/'
      'frustbite-assets-v0.0.1/x.so',
    );
  });

  group('asset download and verification', () {
    late Directory dir;
    late HttpServer server;
    var requests = 0;
    final payload = utf8.encode('pretend dylib bytes');
    final payloadHash = sha256.convert(payload).toString();
    final fileName = assetFileName(OS.linux, Architecture.x64, null);

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('frustbite_download_test_');
      requests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        requests++;
        if (request.uri.path.endsWith('/missing.so')) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.add(payload);
        }
        request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    Uri serverUri(String name) =>
        Uri.parse('http://127.0.0.1:${server.port}/$name');

    Future<File> download({
      Map<String, String>? hashes,
      Uri Function(String)? uriFor,
    }) => downloadAsset(
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      iOSSdk: null,
      outputDirectory: dir,
      hashes: hashes ?? {fileName: payloadHash},
      uriFor: uriFor ?? serverUri,
    );

    test('matching hash succeeds', () async {
      final file = await download();
      await verifyAssetHash(
        file,
        fileName: fileName,
        hashes: {fileName: payloadHash},
      );
      expect(file.readAsBytesSync(), payload);
    });

    test('mismatched hash throws and deletes the file', () async {
      final file = await download();
      await expectLater(
        verifyAssetHash(
          file,
          fileName: fileName,
          hashes: {fileName: 'ab' * 32},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('hash mismatch'),
          ),
        ),
      );
      expect(file.existsSync(), isFalse);
    });

    test('HTTP 404 throws an error naming the URL', () async {
      await expectLater(
        downloadAsset(
          targetOS: OS.linux,
          targetArchitecture: Architecture.x64,
          iOSSdk: null,
          outputDirectory: dir,
          hashes: {fileName: payloadHash},
          uriFor: (_) => serverUri('missing.so'),
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('404'), contains('/missing.so')),
          ),
        ),
      );
    });

    test('failed downloads leave no file behind', () async {
      await expectLater(
        downloadAsset(
          targetOS: OS.linux,
          targetArchitecture: Architecture.x64,
          iOSSdk: null,
          outputDirectory: dir,
          hashes: {fileName: payloadHash},
          uriFor: (_) => serverUri('missing.so'),
        ),
        throwsA(isA<HttpException>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('a body that fails midway leaves no file behind', () async {
      final broken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => broken.close());
      broken.listen((socket) async {
        socket.add(
          ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc'),
        );
        await socket.flush();
        socket.destroy();
      });
      await expectLater(
        downloadAsset(
          targetOS: OS.linux,
          targetArchitecture: Architecture.x64,
          iOSSdk: null,
          outputDirectory: dir,
          hashes: {fileName: payloadHash},
          uriFor: (name) => Uri.parse('http://127.0.0.1:${broken.port}/$name'),
        ),
        throwsA(anything),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('rejects non-https, non-loopback URLs', () async {
      await expectLater(
        downloadAsset(
          targetOS: OS.linux,
          targetArchitecture: Architecture.x64,
          iOSSdk: null,
          outputDirectory: dir,
          hashes: {fileName: payloadHash},
          uriFor: (name) => Uri.parse('http://example.com/$name'),
        ),
        throwsArgumentError,
      );
    });

    test('missing hash throws StateError before any network call', () async {
      await expectLater(
        download(hashes: const {}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'No hash for $fileName; this package version has no prebuilt '
                'binaries — set hooks.user_defines.frustbite.local_build: true',
          ),
        ),
      );
      expect(requests, 0);
    });
  });
}
