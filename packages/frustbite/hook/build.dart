import 'package:code_assets/code_assets.dart';
import 'package:frustbite/src/hook/local_build.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Accessing the code config throws on platforms without code assets (web).
    try {
      input.config.code;
    } catch (_) {
      return;
    }

    // Prebuilt binary download arrives in a later task; always build from source for now.
    await runLocalBuild(input, output, formats: readFormats(input));
  });
}
