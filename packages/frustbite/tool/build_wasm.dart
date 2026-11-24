import 'dart:io';

/// Builds `frustbite.wasm` from `native/` in release mode and copies it to the
/// path given as the only argument (default: `frustbite.wasm` in the current
/// directory).
///
/// ```sh
/// dart tool/build_wasm.dart test/frustbite.wasm
/// ```
Future<void> main(List<String> arguments) async {
  if (arguments.length > 1) {
    stderr.writeln('Usage: dart tool/build_wasm.dart [output.wasm]');
    exit(64);
  }
  final packageDir = File.fromUri(Platform.script).absolute.parent.parent;
  final nativeDir = Directory.fromUri(packageDir.uri.resolve('../../native/'));
  final output = File(
    arguments.isEmpty ? 'frustbite.wasm' : arguments.single,
  ).absolute;

  final process = await Process.start(
    'cargo',
    ['build', '--release', '--target', 'wasm32-unknown-unknown'],
    workingDirectory: nativeDir.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) exit(code);

  final built = File.fromUri(
    nativeDir.uri.resolve(
      'target/wasm32-unknown-unknown/release/frustbite.wasm',
    ),
  );
  await output.parent.create(recursive: true);
  await built.copy(output.path);
  stdout.writeln('Built ${output.path} (${await output.length()} bytes)');
}
