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
import '../waveform.dart';

@JS('WebAssembly.instantiate')
external JSPromise<_InstantiatedSource> _instantiate(
  JSObject bytes,
  JSObject imports,
);

@JS('fetch')
external JSPromise<_Response> _fetch(String url);

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
}

/// `FrustbiteAudioInfo` on wasm32 (`#[repr(C)]`): six `u32`, then two `u64`.
const _infoSize = 40;
const _infoAlign = 8;

/// Size of a pointer or `size_t` on wasm32.
const _word = 4;

/// One instantiated `frustbite.wasm`. Handles are wasm pointers (ints).
///
/// Every call copies its input into wasm memory, reads the out-params from
/// scratch slots, copies the results out and frees every allocation in a
/// `finally`. The memory buffer is re-read after each call, since it detaches
/// when wasm memory grows.
final class WasmRuntime {
  WasmRuntime._(this._exports);

  final _Exports _exports;

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
      exports = source.instance.exports;
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

  int get abiVersion => _exports.abiVersion();

  /// Opens [bytes]; returns the handle. [format] is a wire value.
  int openMemory(Uint8List bytes, int format) =>
      // One block: the out-handle slot, then the bytes.
      _withAlloc(_word + bytes.length, _word, (block) {
        Uint8List.view(_buffer, block + _word, bytes.length).setAll(0, bytes);
        checkError(
          _exports.openMemory(block + _word, bytes.length, format, block),
          'input: memory',
        );
        final handle = _u32(block);
        if (handle == 0) {
          throw UnknownFrustbiteException(
            FrustbiteErrorCode.unknown,
            'input: memory',
          );
        }
        return handle;
      });

  void free(int handle) => _exports.free(handle);

  int sourceByteLength(int handle) =>
      _exports.sourceByteLength(handle).toUnsigned(32);

  AudioInfo info(int handle) => _withAlloc(_infoSize, _infoAlign, (out) {
    checkError(_exports.getInfo(handle, out), 'operation: info');
    final data = ByteData.view(_buffer, out, _infoSize);
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
    checkError(
      _exports.getTagsJson(handle, out, out + _word),
      'operation: tags',
    );
    final ptr = _u32(out);
    final len = _u32(out + _word);
    try {
      final bytes = _copyBytes(ptr, len);
      if (bytes.isEmpty) return AudioTags.empty;
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      return AudioTags.fromJson(json);
    } finally {
      _freeBytes(ptr, len);
    }
  });

  AudioCover? cover(int handle) => _withAlloc(4 * _word, _word, (out) {
    checkError(
      _exports.getCover(
        handle,
        out,
        out + _word,
        out + 2 * _word,
        out + 3 * _word,
      ),
      'operation: cover',
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
    checkError(
      _exports.waveform(
        handle,
        buckets,
        mode.wireValue,
        perChannel ? 1 : 0,
        out,
        out + _word,
      ),
      'operation: waveform',
    );
    final data = _takeFloats(_u32(out), _u32(out + _word));
    return Waveform(
      data: data,
      buckets: buckets,
      channels: data.length ~/ buckets,
    );
  });

  AudioPcm decode(int handle) => _withAlloc(4 * _word, _word, (out) {
    checkError(
      _exports.decode(
        handle,
        out,
        out + _word,
        out + 2 * _word,
        out + 3 * _word,
      ),
      'operation: decode',
    );
    final sampleRate = _u32(out + 2 * _word);
    final channels = _u32(out + 3 * _word);
    return AudioPcm(
      samples: _takeFloats(_u32(out), _u32(out + _word)),
      sampleRate: sampleRate,
      channels: channels,
    );
  });

  /// The current memory buffer. Never cache it across wasm calls.
  ByteBuffer get _buffer => _exports.memory.buffer.toDart;

  int _u32(int ptr) =>
      ByteData.view(_buffer, ptr, 4).getUint32(0, Endian.little);

  /// Runs [use] with [size] bytes of wasm memory, freed afterwards.
  T _withAlloc<T>(int size, int align, T Function(int ptr) use) {
    final ptr = _exports.alloc(size, align).toUnsigned(32);
    if (ptr == 0) {
      throw StateError('WebAssembly allocation of $size bytes failed');
    }
    try {
      return use(ptr);
    } finally {
      _exports.dealloc(ptr, size, align);
    }
  }

  /// Copies a wasm byte buffer into Dart memory. Does not free it.
  Uint8List _copyBytes(int ptr, int len) => ptr == 0 || len == 0
      ? Uint8List(0)
      : Uint8List.fromList(Uint8List.view(_buffer, ptr, len));

  void _freeBytes(int ptr, int len) {
    if (ptr != 0) _exports.freeBytes(ptr, len);
  }

  /// Copies a wasm f32 buffer into Dart memory and frees it.
  Float32List _takeFloats(int ptr, int len) {
    if (ptr == 0) return Float32List(0);
    try {
      return Float32List.fromList(Float32List.view(_buffer, ptr, len));
    } finally {
      _exports.freeF32(ptr, len);
    }
  }
}
