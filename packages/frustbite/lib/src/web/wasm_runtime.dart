import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import '../abi.dart';
import '../audio_enums.dart';
import '../audio_info.dart';
import '../audio_pcm.dart';
import '../audio_tags.dart';
import '../enums.dart';
import '../frustbite_exception.dart';
import '../silence_range.dart';
import '../waveform.dart';

@JS('WebAssembly.instantiate')
external JSPromise<_InstantiatedSource> _instantiate(
  JSObject bytes,
  JSObject imports,
);

@JS('fetch')
external JSPromise<_Response> _fetch(String url);

@JS('Function')
external JSFunction _jsFunction(String parameter, String body);

/// Wraps every exported function in a JS frame that turns a trap into a fresh
/// `Error`. V8 marks a trap's `RuntimeError` as uncatchable by wasm code, even
/// when rethrown, so under dart2wasm (whose Dart frames are wasm) a raw trap
/// would skip every Dart `catch` and `finally`.
const _guardExports = r'''
const guarded = {};
for (const name of Object.keys(exports)) {
  const value = exports[name];
  guarded[name] = typeof value !== 'function' ? value : function (...args) {
    try {
      return value(...args);
    } catch (e) {
      const error = new Error(String(e));
      error.cause = e;
      throw error;
    }
  };
}
return guarded;
''';

/// The guarded exports, or the raw ones where a Content Security Policy
/// without `unsafe-eval` forbids `Function`. Traps are then still caught under
/// dart2js, but under dart2wasm they escape uncaught.
JSObject _guard(JSObject exports) {
  try {
    return _jsFunction('exports', _guardExports).callAsFunction(null, exports)
        as JSObject;
  } catch (_) {
    return exports;
  }
}

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _InstantiatedSource._(JSObject _) implements JSObject {
  external _Instance get instance;
}

extension type _Instance._(JSObject _) implements JSObject {
  external _Exports get exports;
}

extension type _Memory._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}

extension on JSUint8Array {
  /// `TypedArray.prototype.set`: one bulk copy, under dart2js and dart2wasm.
  @JS('set')
  external void setFrom(JSUint8Array source);
}

/// The exports of `frustbite.wasm`: the C ABI of `frustbite.h` plus the wasm32
/// allocator. Pointers and `size_t` are 32-bit; `bool` is passed as 0 or 1.
extension type _Exports._(JSObject _) implements JSObject {
  external _Memory get memory;

  @JS('frustbite_abi_version')
  external int abiVersion();

  @JS('frustbite_alloc')
  external int alloc(int size, int align);

  @JS('frustbite_dealloc')
  external void dealloc(int ptr, int size, int align);

  @JS('frustbite_open_memory')
  external int openMemory(int data, int len, int format, int out);

  @JS('frustbite_free')
  external void free(int audio);

  @JS('frustbite_get_info')
  external int getInfo(int audio, int out);

  @JS('frustbite_source_byte_length')
  external int sourceByteLength(int audio);

  @JS('frustbite_decode')
  external int decode(
    int audio,
    int outSamples,
    int outLen,
    int outSampleRate,
    int outChannels,
  );

  @JS('frustbite_waveform')
  external int waveform(
    int audio,
    int buckets,
    int mode,
    int perChannel,
    int out,
    int outLen,
  );

  @JS('frustbite_free_f32')
  external void freeF32(int ptr, int len);

  @JS('frustbite_get_tags_json')
  external int getTagsJson(int audio, int out, int outLen);

  @JS('frustbite_get_cover')
  external int getCover(
    int audio,
    int out,
    int outLen,
    int outMime,
    int outMimeLen,
  );

  @JS('frustbite_free_bytes')
  external void freeBytes(int ptr, int len);

  @JS('frustbite_render')
  external int render(
    int audio,
    int sources,
    int sourcesLen,
    int ops,
    int opsLen,
    int out,
  );

  @JS('frustbite_render_wav')
  external int renderWav(
    int audio,
    int sources,
    int sourcesLen,
    int ops,
    int opsLen,
    int format,
    int out,
    int outLen,
  );

  @JS('frustbite_detect_silence')
  external int detectSilence(
    int audio,
    double thresholdDb,
    int minDurationMs,
    int out,
    int outLen,
  );

  @JS('frustbite_free_u64')
  external void freeU64(int ptr, int len);
}

/// `FrustbiteAudioInfo` on wasm32 (`#[repr(C)]`): six `u32`, then two `u64`.
const _infoSize = 40;
const _infoAlign = 8;

/// Size of a pointer or `size_t` on wasm32.
const _word = 4;

const _trappedMessage =
    'frustbite wasm runtime trapped; reload the page or call '
    'Frustbite.initialize again';

/// One instantiated `frustbite.wasm`. Handles are wasm pointers (ints).
///
/// Every call copies its input into wasm memory, reads the out-params from
/// scratch slots, copies the results out and frees every allocation in a
/// `finally`. Copies are bulk (`TypedArray.set` in, `fromList` of a typed
/// array view out). The memory buffer is re-read after each call, since it
/// detaches when wasm memory grows.
///
/// A trap (a Rust panic on wasm32, or any JS error out of an export) is
/// reported as [UnknownFrustbiteException] and poisons the instance: its
/// state may be inconsistent, so every later call throws [StateError] and
/// frees are skipped.
final class WasmRuntime {
  WasmRuntime._(this._exports);

  final _Exports _exports;
  bool _trapped = false;

  /// Whether an export trapped; the instance is then unusable.
  bool get isTrapped => _trapped;

  /// Fetches and instantiates the module, then checks its ABI version.
  ///
  /// Pass at most one of [wasmUri] and [wasmBytes]. With neither, the module is
  /// fetched from `frustbite.wasm` next to the page. Throws [StateError] if
  /// the module cannot be loaded or its ABI does not match this package.
  static Future<WasmRuntime> load({Uri? wasmUri, Uint8List? wasmBytes}) async {
    if (wasmUri != null && wasmBytes != null) {
      throw ArgumentError('Provide wasmUri or wasmBytes, not both');
    }
    final JSObject bytes;
    if (wasmBytes != null) {
      bytes = wasmBytes.toJS;
    } else {
      final uri = wasmUri ?? Uri.base.resolve('frustbite.wasm');
      final response = await _fetch(uri.toString()).toDart;
      if (!response.ok) {
        throw StateError(
          'Failed to load the Frustbite WebAssembly module from $uri: '
          'HTTP ${response.status}',
        );
      }
      bytes = await response.arrayBuffer().toDart;
    }

    final _Exports exports;
    try {
      final source = await _instantiate(bytes, JSObject()).toDart;
      exports = _Exports._(_guard(source.instance.exports));
    } catch (error) {
      throw StateError(
        'Failed to instantiate the Frustbite WebAssembly module: $error',
      );
    }
    final int version;
    try {
      version = exports.abiVersion();
    } catch (error) {
      throw StateError(
        'Frustbite WASM has no usable ABI version. Rebuild or download the '
        'frustbite.wasm matching this Frustbite package. Cause: $error',
      );
    }
    checkFrustbiteAbi(version);
    return WasmRuntime._(exports);
  }

  int get abiVersion =>
      _call('operation: abiVersion', () => _exports.abiVersion());

  /// Opens [bytes]; returns the handle. [format] is a wire value.
  int openMemory(Uint8List bytes, int format) =>
      // One block: the out-handle slot, then the bytes.
      _withAlloc(_word + bytes.length, _word, (block) {
        JSUint8Array(_memory, block + _word, bytes.length).setFrom(bytes.toJS);
        const context = 'input: memory';
        checkError(
          _call(
            context,
            () =>
                _exports.openMemory(block + _word, bytes.length, format, block),
          ),
          context,
        );
        final handle = _u32(block);
        if (handle == 0) {
          throw frustbiteError(FrustbiteErrorCode.unknown, 'input: memory');
        }
        return handle;
      });

  /// Frees [handle]; skipped once the instance has trapped.
  void free(int handle) => _release(() => _exports.free(handle));

  int sourceByteLength(int handle) => _call(
    'operation: sourceByteLength',
    () => _exports.sourceByteLength(handle),
  ).toUnsigned(32);

  AudioInfo info(int handle) => _withAlloc(_infoSize, _infoAlign, (out) {
    const context = 'operation: info';
    checkError(_call(context, () => _exports.getInfo(handle, out)), context);
    final data = ByteData.view(_memory.toDart, out, _infoSize);
    int u32(int offset) => data.getUint32(offset, Endian.little);
    // dart2js has no ByteData.getUint64; combine the two halves.
    int u64(int offset) => u32(offset) + u32(offset + 4) * 0x100000000;
    final bitsPerSample = u32(16);
    final bitrate = u32(20);
    return AudioInfo(
      container: AudioContainerWire.fromWire(u32(0)),
      codec: AudioCodecWire.fromWire(u32(4)),
      sampleRate: u32(8),
      channels: u32(12),
      bitsPerSample: bitsPerSample == 0 ? null : bitsPerSample,
      bitrate: bitrate == 0 ? null : bitrate,
      totalFrames: u64(24),
      duration: Duration(microseconds: u64(32)),
    );
  });

  AudioTags tags(int handle) => _withAlloc(2 * _word, _word, (out) {
    const context = 'operation: tags';
    checkError(
      _call(context, () => _exports.getTagsJson(handle, out, out + _word)),
      context,
    );
    final ptr = _u32(out);
    final len = _u32(out + _word);
    try {
      final bytes = _copyBytes(ptr, len);
      if (bytes.isEmpty) return AudioTags.empty;
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      return audioTagsFromJson(json);
    } finally {
      _freeBytes(ptr, len);
    }
  });

  AudioCover? cover(int handle) => _withAlloc(4 * _word, _word, (out) {
    const context = 'operation: cover';
    checkError(
      _call(
        context,
        () => _exports.getCover(
          handle,
          out,
          out + _word,
          out + 2 * _word,
          out + 3 * _word,
        ),
      ),
      context,
    );
    final ptr = _u32(out);
    final len = _u32(out + _word);
    final mimePtr = _u32(out + 2 * _word);
    final mimeLen = _u32(out + 3 * _word);
    // Both buffers are freed even if a copy throws.
    try {
      final data = _copyBytes(ptr, len);
      final mime = _copyBytes(mimePtr, mimeLen);
      if (data.isEmpty) return null;
      return AudioCover(data: data, mimeType: utf8.decode(mime));
    } finally {
      _freeBytes(ptr, len);
      _freeBytes(mimePtr, mimeLen);
    }
  });

  Waveform waveform(
    int handle,
    int buckets,
    WaveformMode mode,
    bool perChannel,
  ) => _withAlloc(2 * _word, _word, (out) {
    const context = 'operation: waveform';
    checkError(
      _call(
        context,
        () => _exports.waveform(
          handle,
          buckets,
          mode.wireValue,
          perChannel ? 1 : 0,
          out,
          out + _word,
        ),
      ),
      context,
    );
    final data = _takeFloats(_u32(out), _u32(out + _word));
    return Waveform(
      data: data,
      buckets: buckets,
      channels: data.length ~/ buckets,
    );
  });

  AudioPcm decode(int handle) => _withAlloc(4 * _word, _word, (out) {
    const context = 'operation: decode';
    checkError(
      _call(
        context,
        () => _exports.decode(
          handle,
          out,
          out + _word,
          out + 2 * _word,
          out + 3 * _word,
        ),
      ),
      context,
    );
    final sampleRate = _u32(out + 2 * _word);
    final channels = _u32(out + 3 * _word);
    return AudioPcm(
      samples: _takeFloats(_u32(out), _u32(out + _word)),
      sampleRate: sampleRate,
      channels: channels,
    );
  });

  /// Runs [call] with one block holding two out slots, the [sources] handles
  /// and the [ops] bytes: `[out | outLen | sources... | ops...]`. [call]
  /// gets the block, the sources pointer (0 when empty) and the ops pointer
  /// (0 when empty).
  T _withRenderBlock<T>(
    List<int> sources,
    Uint8List ops,
    T Function(int block, int sourcesPtr, int opsPtr) call,
  ) {
    final sourcesOffset = 2 * _word;
    final opsOffset = sourcesOffset + sources.length * _word;
    return _withAlloc(opsOffset + ops.length, _word, (block) {
      final view = ByteData.view(_memory.toDart, block, opsOffset);
      for (var i = 0; i < sources.length; i++) {
        view.setUint32(sourcesOffset + i * _word, sources[i], Endian.little);
      }
      if (ops.isNotEmpty) {
        JSUint8Array(_memory, block + opsOffset, ops.length).setFrom(ops.toJS);
      }
      return call(
        block,
        sources.isEmpty ? 0 : block + sourcesOffset,
        ops.isEmpty ? 0 : block + opsOffset,
      );
    });
  }

  /// Renders [handle] with [ops]; returns the new handle.
  int render(int handle, List<int> sources, Uint8List ops) =>
      _withRenderBlock(sources, ops, (block, sourcesPtr, opsPtr) {
        const context = 'operation: render';
        checkError(
          _call(
            context,
            () => _exports.render(
              handle,
              sourcesPtr,
              sources.length,
              opsPtr,
              ops.length,
              block,
            ),
          ),
          context,
        );
        final result = _u32(block);
        if (result == 0) {
          throw frustbiteError(FrustbiteErrorCode.unknown, context);
        }
        return result;
      });

  /// Renders [handle] with [ops] to WAV bytes in [format] (a wire value).
  Uint8List renderWav(
    int handle,
    List<int> sources,
    Uint8List ops,
    int format,
  ) => _withRenderBlock(sources, ops, (block, sourcesPtr, opsPtr) {
    const context = 'operation: toWav';
    checkError(
      _call(
        context,
        () => _exports.renderWav(
          handle,
          sourcesPtr,
          sources.length,
          opsPtr,
          ops.length,
          format,
          block,
          block + _word,
        ),
      ),
      context,
    );
    final ptr = _u32(block);
    final len = _u32(block + _word);
    try {
      return _copyBytes(ptr, len);
    } finally {
      _freeBytes(ptr, len);
    }
  });

  /// Silent stretches of [handle].
  List<SilenceRange> detectSilence(
    int handle,
    double thresholdDb,
    int minDurationMs,
  ) => _withAlloc(2 * _word, _word, (out) {
    const context = 'operation: detectSilence';
    checkError(
      _call(
        context,
        () => _exports.detectSilence(
          handle,
          thresholdDb,
          minDurationMs,
          out,
          out + _word,
        ),
      ),
      context,
    );
    final ptr = _u32(out);
    final len = _u32(out + _word);
    if (ptr == 0) return const [];
    try {
      final data = ByteData.view(_memory.toDart, ptr, len * 8);
      // dart2js has no ByteData.getUint64; combine the two halves.
      final values = [
        for (var i = 0; i < len; i++)
          data.getUint32(i * 8, Endian.little) +
              data.getUint32(i * 8 + 4, Endian.little) * 0x100000000,
      ];
      return silenceRangesFromMicros(values);
    } finally {
      _release(() => _exports.freeU64(ptr, len));
    }
  });

  /// The current memory buffer. Never cache it across wasm calls.
  JSArrayBuffer get _memory => _exports.memory.buffer;

  int _u32(int ptr) =>
      ByteData.view(_memory.toDart, ptr, 4).getUint32(0, Endian.little);

  /// Calls an export. Anything it throws is a trap: the instance is poisoned
  /// and the trap is reported as [UnknownFrustbiteException].
  T _call<T>(String context, T Function() export) {
    if (_trapped) throw StateError(_trappedMessage);
    try {
      return export();
    } catch (error) {
      _trapped = true;
      throw frustbiteError(
        FrustbiteErrorCode.unknown,
        '$context; the wasm module trapped: $error',
      );
    }
  }

  /// Calls a freeing export, unless the instance trapped: its allocator may
  /// be inconsistent, and a pending trap error must not be replaced.
  void _release(void Function() export) {
    if (!_trapped) _call('operation: free', export);
  }

  /// Runs [use] with [size] bytes of wasm memory, freed afterwards.
  T _withAlloc<T>(int size, int align, T Function(int ptr) use) {
    final ptr = _call(
      'operation: alloc',
      () => _exports.alloc(size, align),
    ).toUnsigned(32);
    if (ptr == 0) {
      throw StateError('WebAssembly allocation of $size bytes failed');
    }
    try {
      return use(ptr);
    } finally {
      _release(() => _exports.dealloc(ptr, size, align));
    }
  }

  /// Copies a wasm byte buffer into Dart memory in one bulk copy. Does not
  /// free it.
  Uint8List _copyBytes(int ptr, int len) => ptr == 0 || len == 0
      ? Uint8List(0)
      : Uint8List.fromList(JSUint8Array(_memory, ptr, len).toDart);

  void _freeBytes(int ptr, int len) {
    if (ptr != 0) _release(() => _exports.freeBytes(ptr, len));
  }

  /// Copies a wasm f32 buffer into Dart memory in one bulk copy and frees it.
  Float32List _takeFloats(int ptr, int len) {
    if (ptr == 0) return Float32List(0);
    try {
      return Float32List.fromList(JSFloat32Array(_memory, ptr, len).toDart);
    } finally {
      _release(() => _exports.freeF32(ptr, len));
    }
  }
}
