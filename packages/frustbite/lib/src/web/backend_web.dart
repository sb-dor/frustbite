import 'dart:typed_data';

import '../audio_enums.dart';
import '../audio_info.dart';
import '../audio_pcm.dart';
import '../audio_tags.dart';
import '../waveform.dart';
import 'wasm_runtime.dart';

/// Owns a handle (a wasm pointer) in the initialized WASM instance. The
/// public API guards access after disposal.
final class BackendAudio {
  BackendAudio._(this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  final int _handle;

  static WasmRuntime? _runtime;
  static Future<WasmRuntime>? _loading;

  // Web has no NativeFinalizer; this is a best-effort safety net only.
  static final _finalizer = Finalizer<int>((handle) => _runtime?.free(handle));

  static WasmRuntime get _wasm =>
      _runtime ??
      (throw StateError(
        'Call Frustbite.initialize() before using frustbite on the web',
      ));

  static int get abiVersion => _wasm.abiVersion;

  /// Loads and checks the module once. Concurrent calls share one load; a
  /// failed load can be retried.
  static Future<void> initialize({Uint8List? wasmBytes, Uri? wasmUri}) async {
    if (wasmBytes != null && wasmUri != null) {
      throw ArgumentError('Provide wasmUri or wasmBytes, not both');
    }
    if (_runtime != null) return;
    final loading = _loading ??= WasmRuntime.load(
      wasmUri: wasmUri,
      wasmBytes: wasmBytes,
    );
    try {
      _runtime = await loading;
    } finally {
      if (_runtime == null) _loading = null;
    }
  }

  /// Throws [UnsupportedError]: the web has no file system.
  static void ensureFilesSupported() => throw UnsupportedError(_noFiles);

  factory BackendAudio.fromMemory(Uint8List bytes, AudioContainer? format) =>
      BackendAudio._(
        _wasm.openMemory(bytes, format?.wireValue ?? formatDetectWire),
      );

  factory BackendAudio.fromFile(String path, AudioContainer? format) =>
      throw UnsupportedError(_noFiles);

  /// The handle: a pointer into wasm memory.
  int get address => _handle;

  int get sourceByteLength => _wasm.sourceByteLength(_handle);

  AudioInfo info() => _wasm.info(_handle);

  AudioTags tags() => _wasm.tags(_handle);

  AudioCover? cover() => _wasm.cover(_handle);

  Waveform waveform(int buckets, WaveformMode mode, bool perChannel) =>
      _wasm.waveform(_handle, buckets, mode, perChannel);

  AudioPcm decode() => _wasm.decode(_handle);

  // No isolates for wasm memory: the sync call runs in a later event-loop
  // turn. The closure keeps `this` reachable until it has run.
  Future<Waveform> waveformAsync(
    int buckets,
    WaveformMode mode,
    bool perChannel,
  ) => Future(() => waveform(buckets, mode, perChannel));

  Future<AudioPcm> decodeAsync() => Future(decode);

  void dispose() {
    _finalizer.detach(this);
    _wasm.free(_handle);
  }
}

const _noFiles =
    'Frustbite.fromFile is unavailable on the web; use Frustbite.fromMemory';
