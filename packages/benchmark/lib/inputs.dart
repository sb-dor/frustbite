import 'dart:io';
import 'dart:typed_data';

/// The generated benchmark files (see `tool/generate_inputs.sh`), loaded once.
final class Inputs {
  Inputs._(this.dir, this.mp3, this.ogg, this.flac, this.wav);

  /// Absolute path of the `inputs/` directory.
  final String dir;
  final Uint8List mp3;
  final Uint8List ogg;
  final Uint8List flac;
  final Uint8List wav;

  /// Path of the mp3 on disk, for baselines that only accept a [File].
  String get mp3Path => '$dir/music.mp3';

  /// Loads the inputs from `<package>/inputs`, resolved relative to this
  /// script so `dart run` works from any directory.
  static Inputs load() {
    final dir = Directory.fromUri(
      Platform.script.resolve('../inputs'),
    ).absolute.path;
    Uint8List read(String name) {
      final file = File('$dir/$name');
      if (!file.existsSync()) {
        throw StateError(
          'Missing $dir/$name. Run tool/generate_inputs.sh first.',
        );
      }
      return file.readAsBytesSync();
    }

    return Inputs._(
      dir,
      read('music.mp3'),
      read('music.ogg'),
      read('music.flac'),
      read('music.wav'),
    );
  }
}
