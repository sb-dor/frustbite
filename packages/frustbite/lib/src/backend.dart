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
//   void dispose();
// }
// ```
export 'backend_native.dart'
    if (dart.library.js_interop) 'web/backend_web.dart';
