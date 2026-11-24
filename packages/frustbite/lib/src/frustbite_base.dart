import 'dart:typed_data';

import 'audio_enums.dart';
import 'audio_info.dart';
import 'audio_pcm.dart';
import 'audio_tags.dart';
import 'backend.dart';
import 'enums.dart';
import 'frustbite_exception.dart';
import 'waveform.dart';

/// An opened audio source, backed by Rust on native and web platforms.
///
/// Call [dispose] when done. Finalizers are only a safety net. Using a
/// disposed instance throws [StateError]. On web, await [initialize] first.
///
/// ```dart
/// final audio = Frustbite.fromFile('song.mp3');
/// print(audio.info.duration);
/// final peaks = audio.waveform(buckets: 200);
/// audio.dispose();
/// ```
final class Frustbite {
  Frustbite._(this._backend);

  final BackendAudio _backend;
  bool _isDisposed = false;
  AudioInfo? _info;
  AudioTags? _tags;
  AudioCover? _cover;
  bool _coverRead = false;

  /// Async operations in flight. `this` stays referenced by the running async
  /// method, so the finalizer cannot run before they complete.
  int _busy = 0;

  static void _checkBuckets(int buckets) {
    if (buckets < 1 || buckets > 100000) {
      throw frustbiteError(
        FrustbiteErrorCode.invalidParameter,
        'buckets must be in 1..100000',
      );
    }
  }

  /// ABI version of the loaded native library, verified against this package.
  static int get abiVersion => BackendAudio.abiVersion;

  /// Loads the WASM module on web; a no-op on native platforms.
  ///
  /// On web, call and await this before any other use, or that use throws
  /// [StateError]. With no argument, `frustbite.wasm` is fetched relative to
  /// the page; pass [wasmUri] or [wasmBytes] (not both) to load it from
  /// elsewhere. Throws [StateError] if the module cannot be loaded or does not
  /// match this package's ABI; a failed load can be retried. If the engine
  /// traps (reported as [UnknownFrustbiteException]), every later call throws
  /// [StateError] until this is called again, which loads a fresh instance;
  /// objects opened before the trap stay unusable.
  static Future<void> initialize({Uri? wasmUri, Uint8List? wasmBytes}) =>
      BackendAudio.initialize(wasmUri: wasmUri, wasmBytes: wasmBytes);

  /// Opens audio from [bytes]. The container is detected from the content;
  /// [format] is only an advisory hint, and a wrong hint is not an error.
  ///
  /// Throws [DecodingException] if [bytes] is empty or corrupt, and
  /// [UnsupportedFormatException] if the format is not supported.
  factory Frustbite.fromMemory(Uint8List bytes, {AudioContainer? format}) {
    if (bytes.isEmpty) {
      throw frustbiteError(
        FrustbiteErrorCode.decodingError,
        'input buffer is empty',
      );
    }
    return Frustbite._(BackendAudio.fromMemory(bytes, format));
  }

  /// Opens audio from the file at [path]. [format] is only an advisory hint:
  /// content detection wins, and a wrong hint is not an error.
  ///
  /// Throws [InvalidPathException] if the path is empty or missing. On web it
  /// always throws [UnsupportedError], before any other check; use
  /// [Frustbite.fromMemory] instead.
  factory Frustbite.fromFile(String path, {AudioContainer? format}) {
    BackendAudio.ensureFilesSupported();
    if (path.trim().isEmpty) {
      throw frustbiteError(FrustbiteErrorCode.invalidPath, 'path is empty');
    }
    return Frustbite._(BackendAudio.fromFile(path, format));
  }

  /// Whether [dispose] has been called.
  bool get isDisposed => _isDisposed;

  void _checkDisposed() {
    if (_isDisposed) throw StateError('Frustbite has been disposed');
  }

  /// Stream description (cached).
  AudioInfo get info {
    _checkDisposed();
    return _info ??= _backend.info();
  }

  /// Metadata tags (cached). Empty when the source has none.
  AudioTags get tags {
    _checkDisposed();
    return _tags ??= _backend.tags();
  }

  /// Embedded cover art (cached), or null.
  AudioCover? get cover {
    _checkDisposed();
    if (!_coverRead) {
      _cover = _backend.cover();
      _coverRead = true;
    }
    return _cover;
  }

  /// Summarises the source into [buckets] amplitudes in [0, 1].
  ///
  /// Decodes the whole source; heavy for long files. Throws
  /// [InvalidParameterException] unless [buckets] is in 1..100000.
  Waveform waveform({
    int buckets = 100,
    WaveformMode mode = WaveformMode.peak,
    bool perChannel = false,
  }) {
    _checkDisposed();
    _checkBuckets(buckets);
    return _backend.waveform(buckets, mode, perChannel);
  }

  /// Decodes the whole source to interleaved f32 PCM. Heavy for long files.
  AudioPcm decode() {
    _checkDisposed();
    return _backend.decode();
  }

  /// Like [waveform], but runs on a background isolate. On web, where wasm
  /// memory cannot be shared with another isolate, it runs on the same thread
  /// in a later event-loop turn.
  ///
  /// [dispose] throws [StateError] while this is in flight.
  Future<Waveform> waveformAsync({
    int buckets = 100,
    WaveformMode mode = WaveformMode.peak,
    bool perChannel = false,
  }) async {
    _checkDisposed();
    _checkBuckets(buckets);
    _busy++;
    try {
      return await _backend.waveformAsync(buckets, mode, perChannel);
    } finally {
      _busy--;
    }
  }

  /// Like [decode], but runs on a background isolate (on web: in a later
  /// event-loop turn, as with [waveformAsync]).
  ///
  /// [dispose] throws [StateError] while this is in flight.
  Future<AudioPcm> decodeAsync() async {
    _checkDisposed();
    _busy++;
    try {
      return await _backend.decodeAsync();
    } finally {
      _busy--;
    }
  }

  /// Releases the native resources. Safe to call more than once.
  void dispose() {
    if (_isDisposed) return;
    if (_busy > 0) {
      throw StateError('Cannot dispose while an async operation is running');
    }
    _isDisposed = true;
    _backend.dispose();
  }
}
