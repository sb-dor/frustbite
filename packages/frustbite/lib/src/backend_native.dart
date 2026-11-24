import 'dart:convert';
import 'dart:isolate';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;

import 'abi.dart';
import 'audio_enums.dart';
import 'audio_info.dart';
import 'audio_pcm.dart';
import 'audio_tags.dart';
import 'bindings/bindings.dart';
import 'frustbite_exception.dart';
import 'waveform.dart';

/// Owns a native handle. The public API guards access after disposal.
final class BackendAudio implements ffi.Finalizable {
  BackendAudio._(this._handle) {
    _finalizer.attach(
      this,
      _handle.cast(),
      detach: this,
      externalSize: frustbite_source_byte_length(_handle),
    );
  }

  final ffi.Pointer<FrustbiteAudio> _handle;

  static final _finalizer = ffi.NativeFinalizer(
    ffi.Native.addressOf<
          ffi.NativeFunction<ffi.Void Function(ffi.Pointer<FrustbiteAudio>)>
        >(frustbite_free)
        .cast(),
  );

  // Evaluated once; throws on mismatch.
  static final bool _compatible = _checkAbi();

  static bool _checkAbi() {
    final int version;
    try {
      version = frustbite_abi_version();
    } catch (error) {
      throw StateError(
        'Frustbite binary has no usable ABI version. Rebuild or download the '
        'binary matching this Frustbite package. Cause: $error',
      );
    }
    checkFrustbiteAbi(version);
    return true;
  }

  static void _ensureCompatible() => _compatible;

  static int get abiVersion {
    _ensureCompatible();
    return frustbite_abi_version();
  }

  static Future<void> initialize({Uint8List? wasmBytes, Uri? wasmUri}) async {
    _ensureCompatible();
  }

  factory BackendAudio.fromMemory(Uint8List bytes, AudioContainer? format) =>
      ffi.using((arena) {
        _ensureCompatible();
        final data = arena<ffi.Uint8>(bytes.length)
          ..asTypedList(bytes.length).setAll(0, bytes);
        final out = arena<ffi.Pointer<FrustbiteAudio>>();
        checkError(
          frustbite_open_memory(
            data,
            bytes.length,
            format?.wireValue ?? FRUSTBITE_FORMAT_DETECT,
            out,
          ),
          'input: memory',
        );
        return BackendAudio._(out.value);
      });

  factory BackendAudio.fromFile(String path, AudioContainer? format) =>
      ffi.using((arena) {
        _ensureCompatible();
        final out = arena<ffi.Pointer<FrustbiteAudio>>();
        checkError(
          frustbite_open_file(
            path.toNativeUtf8(allocator: arena).cast(),
            format?.wireValue ?? FRUSTBITE_FORMAT_DETECT,
            out,
          ),
          'path: $path',
        );
        return BackendAudio._(out.value);
      });

  /// Raw handle address, for calls inside another isolate.
  int get address => _handle.address;

  int get sourceByteLength => frustbite_source_byte_length(_handle);

  AudioInfo info() => nativeInfo(address);

  AudioTags tags() => nativeTags(address);

  AudioCover? cover() => nativeCover(address);

  Waveform waveform(int buckets, WaveformMode mode, bool perChannel) =>
      nativeWaveform(address, buckets, mode, perChannel);

  AudioPcm decode() => nativeDecode(address);

  // The closures capture only ints and enums, never `this`: a BackendAudio is
  // Finalizable and must not cross isolates. Instead `this` is referenced
  // after the await, so it stays reachable (no finalizer) until the call ends.
  Future<Waveform> waveformAsync(
    int buckets,
    WaveformMode mode,
    bool perChannel,
  ) async {
    final addr = address;
    try {
      return await Isolate.run(
        () => nativeWaveform(addr, buckets, mode, perChannel),
      );
    } finally {
      _keepAlive();
    }
  }

  Future<AudioPcm> decodeAsync() async {
    final addr = address;
    try {
      return await Isolate.run(() => nativeDecode(addr));
    } finally {
      _keepAlive();
    }
  }

  @pragma('vm:never-inline')
  void _keepAlive() {}

  void dispose() {
    _finalizer.detach(this);
    frustbite_free(_handle);
  }
}

ffi.Pointer<FrustbiteAudio> _ptr(int address) =>
    ffi.Pointer<FrustbiteAudio>.fromAddress(address);

/// Reads the info of the handle at [address].
AudioInfo nativeInfo(int address) => ffi.using((arena) {
  final out = arena<FrustbiteAudioInfo>();
  checkError(frustbite_get_info(_ptr(address), out), 'operation: info');
  final r = out.ref;
  return AudioInfo(
    container: AudioContainerWire.fromWire(r.container),
    codec: AudioCodecWire.fromWire(r.codec),
    sampleRate: r.sample_rate,
    channels: r.channels,
    bitsPerSample: r.bits_per_sample == 0 ? null : r.bits_per_sample,
    bitrate: r.bitrate == 0 ? null : r.bitrate,
    totalFrames: r.total_frames,
    duration: Duration(microseconds: r.duration_us),
  );
});

/// Reads the tags of the handle at [address].
AudioTags nativeTags(int address) => ffi.using((arena) {
  final out = arena<ffi.Pointer<ffi.Uint8>>();
  final outLen = arena<ffi.Size>();
  checkError(
    frustbite_get_tags_json(_ptr(address), out, outLen),
    'operation: tags',
  );
  try {
    final bytes = _copyBytes(out.value, outLen.value);
    if (bytes.isEmpty) return AudioTags.empty;
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    return AudioTags.fromJson(json);
  } finally {
    _freeBytes(out.value, outLen.value);
  }
});

/// Reads the cover of the handle at [address]; null when there is none.
AudioCover? nativeCover(int address) => ffi.using((arena) {
  final out = arena<ffi.Pointer<ffi.Uint8>>();
  final outLen = arena<ffi.Size>();
  final mime = arena<ffi.Pointer<ffi.Uint8>>();
  final mimeLen = arena<ffi.Size>();
  checkError(
    frustbite_get_cover(_ptr(address), out, outLen, mime, mimeLen),
    'operation: cover',
  );
  // Both buffers are freed even if the first copy throws.
  try {
    final data = _copyBytes(out.value, outLen.value);
    final mimeBytes = _copyBytes(mime.value, mimeLen.value);
    if (data.isEmpty) return null;
    return AudioCover(data: data, mimeType: utf8.decode(mimeBytes));
  } finally {
    _freeBytes(out.value, outLen.value);
    _freeBytes(mime.value, mimeLen.value);
  }
});

/// Computes a waveform for the handle at [address].
Waveform nativeWaveform(
  int address,
  int buckets,
  WaveformMode mode,
  bool perChannel,
) => ffi.using((arena) {
  final out = arena<ffi.Pointer<ffi.Float>>();
  final outLen = arena<ffi.Size>();
  checkError(
    frustbite_waveform(
      _ptr(address),
      buckets,
      mode.wireValue,
      perChannel,
      out,
      outLen,
    ),
    'operation: waveform',
  );
  final data = _copyFloats(out.value, outLen.value);
  return Waveform(
    data: data,
    buckets: buckets,
    channels: data.length ~/ buckets,
  );
});

/// Decodes the handle at [address] to PCM.
AudioPcm nativeDecode(int address) => ffi.using((arena) {
  final out = arena<ffi.Pointer<ffi.Float>>();
  final outLen = arena<ffi.Size>();
  final rate = arena<ffi.Uint32>();
  final channels = arena<ffi.Uint32>();
  checkError(
    frustbite_decode(_ptr(address), out, outLen, rate, channels),
    'operation: decode',
  );
  final samples = _copyFloats(out.value, outLen.value);
  return AudioPcm(
    samples: samples,
    sampleRate: rate.value,
    channels: channels.value,
  );
});

/// Copies a native byte buffer into Dart memory. Does not free it.
Uint8List _copyBytes(ffi.Pointer<ffi.Uint8> ptr, int len) => ptr == ffi.nullptr
    ? Uint8List(0)
    : Uint8List.fromList(ptr.asTypedList(len));

void _freeBytes(ffi.Pointer<ffi.Uint8> ptr, int len) {
  if (ptr != ffi.nullptr) frustbite_free_bytes(ptr, len);
}

/// Copies a native f32 buffer into Dart memory and frees it.
Float32List _copyFloats(ffi.Pointer<ffi.Float> ptr, int len) {
  if (ptr == ffi.nullptr) return Float32List(0);
  try {
    return Float32List.fromList(ptr.asTypedList(len));
  } finally {
    frustbite_free_f32(ptr, len);
  }
}
