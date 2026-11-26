// The backend surface. Both backends implement exactly this, so `Frustbite`
// stays backend-agnostic:
//
// ```dart
// final class BackendAudio {
//   static int get abiVersion;
//   // Native: checks the ABI. Web: loads the module (required before use).
//   static Future<void> initialize({Uint8List? wasmBytes, Uri? wasmUri});
//   // Native: no-op. Web: throws UnsupportedError.
//   static void ensureFilesSupported();
//   factory BackendAudio.fromMemory(Uint8List bytes, AudioContainer? format);
//   factory BackendAudio.fromFile(String path, AudioContainer? format);
//   // The handle: a native address, or a pointer into wasm memory.
//   int get address;
//   int get sourceByteLength;
//   AudioInfo info();
//   AudioTags tags();
//   AudioCover? cover();
//   Waveform waveform(int buckets, WaveformMode mode, bool perChannel);
//   AudioPcm decode();
//   // Native: on a background isolate. Web: `Future(() => sync call)`.
//   Future<Waveform> waveformAsync(int buckets, WaveformMode mode, bool perChannel);
//   Future<AudioPcm> decodeAsync();
//   // Editing: `ops` is the UTF-8 JSON operation list, `sources` the extra
//   // handles it refers to by index. Web: sources from one wasm instance.
//   BackendAudio render(List<BackendAudio> sources, Uint8List ops);
//   Future<BackendAudio> renderAsync(List<BackendAudio> sources, Uint8List ops);
//   Uint8List renderWav(List<BackendAudio> sources, Uint8List ops, WavFormat format);
//   Future<Uint8List> renderWavAsync(List<BackendAudio> sources, Uint8List ops, WavFormat format);
//   List<SilenceRange> detectSilence(double thresholdDb, int minDurationMs);
//   Future<List<SilenceRange>> detectSilenceAsync(double thresholdDb, int minDurationMs);
//   // Native: no-op / dart:io writes. Web: throw UnsupportedError.
//   static void ensureSaveSupported();
//   static void writeFile(String path, Uint8List bytes);
//   static Future<void> writeFileAsync(String path, Uint8List bytes);
//   void dispose();
// }
// ```
export 'backend_native.dart'
    if (dart.library.js_interop) 'web/backend_web.dart';
