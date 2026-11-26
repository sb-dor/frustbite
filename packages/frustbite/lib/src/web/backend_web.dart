import 'dart:typed_data';

import '../audio_enums.dart';
import '../audio_info.dart';
import '../audio_pcm.dart';
import '../audio_tags.dart';
import '../silence_range.dart';
import '../waveform.dart';
import 'wasm_runtime.dart';

/// Owns a handle (a wasm pointer) in the WASM instance that opened it. The
/// public API guards access after disposal.
final class BackendAudio {
  BackendAudio._(this._wasm, this._handle) {
    _finalizer.attach(this, (_wasm, _handle), detach: this);
  }

  /// The instance that owns [_handle]. Kept per object: after a trap,
  /// [initialize] loads a new instance, and old handles must never reach it.
  final WasmRuntime _wasm;
  final int _handle;

  static WasmRuntime? _runtime;
  static Future<WasmRuntime>? _loading;

  // Web has no NativeFinalizer; this is a best-effort safety net only.
  //
  // The callback must never throw: a trap inside wasm would otherwise surface
  // as an uncaught asynchronous error.
  static final _finalizer = Finalizer<(WasmRuntime, int)>((owner) {
    try {
      owner.$1.free(owner.$2);
    } catch (_) {
      // Nothing to do: the instance is already unusable or the handle is gone.
    }
  });

  static WasmRuntime get _current =>
      _runtime ??
      (throw StateError(
        'Call Frustbite.initialize() before using frustbite on the web',
      ));

  static int get abiVersion => _current.abiVersion;

  /// Loads and checks the module once. Concurrent calls share one load; a
  /// failed load can be retried, and a trapped instance is replaced.
  static Future<void> initialize({Uint8List? wasmBytes, Uri? wasmUri}) async {
    if (wasmBytes != null && wasmUri != null) {
      throw ArgumentError('Provide wasmUri or wasmBytes, not both');
    }
    final current = _runtime;
    if (current != null) {
      if (!current.isTrapped) return;
      _runtime = null;
      _loading = null;
    }
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

  factory BackendAudio.fromMemory(Uint8List bytes, AudioContainer? format) {
    final wasm = _current;
    final handle = wasm.openMemory(
      bytes,
      format?.wireValue ?? formatDetectWire,
    );
    return BackendAudio._(wasm, handle);
  }

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

  /// The handles of [sources], which must live in this object's instance.
  List<int> _handles(List<BackendAudio> sources) => [
    for (final source in sources)
      if (identical(source._wasm, _wasm))
        source._handle
      else
        throw StateError(
          'Cannot combine audio opened before Frustbite.initialize() '
          'reloaded the WebAssembly module with audio opened after it',
        ),
  ];

  BackendAudio render(List<BackendAudio> sources, Uint8List ops) =>
      BackendAudio._(_wasm, _wasm.render(_handle, _handles(sources), ops));

  Future<BackendAudio> renderAsync(List<BackendAudio> sources, Uint8List ops) =>
      Future(() => render(sources, ops));

  Uint8List renderWav(
    List<BackendAudio> sources,
    Uint8List ops,
    WavFormat format,
  ) => _wasm.renderWav(_handle, _handles(sources), ops, format.wireValue);

  Future<Uint8List> renderWavAsync(
    List<BackendAudio> sources,
    Uint8List ops,
    WavFormat format,
  ) => Future(() => renderWav(sources, ops, format));

  List<SilenceRange> detectSilence(double thresholdDb, int minDurationMs) =>
      _wasm.detectSilence(_handle, thresholdDb, minDurationMs);

  Future<List<SilenceRange>> detectSilenceAsync(
    double thresholdDb,
    int minDurationMs,
  ) => Future(() => detectSilence(thresholdDb, minDurationMs));

  /// Throws [UnsupportedError]: the web has no file system.
  static void ensureSaveSupported() => throw UnsupportedError(_noSave);

  /// Throws [UnsupportedError]: the web has no file system.
  static void writeFile(String path, Uint8List bytes) =>
      throw UnsupportedError(_noSave);

  static Future<void> writeFileAsync(String path, Uint8List bytes) =>
      throw UnsupportedError(_noSave);

  /// Frees the handle; a no-op on a trapped instance.
  void dispose() {
    _finalizer.detach(this);
    _wasm.free(_handle);
  }
}

const _noSave =
    'saveWav is unavailable on the web; use toWav and hand the bytes to the '
    'browser (a download or an upload)';

const _noFiles =
    'Frustbite.fromFile is unavailable on the web; use Frustbite.fromMemory';
