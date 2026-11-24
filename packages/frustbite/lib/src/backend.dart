// The backend surface (shared by native and web):
//
// ```dart
// final class BackendAudio {
//   static int get abiVersion;
//   static Future<void> initialize({Uint8List? wasmBytes, Uri? wasmUri});
//   factory BackendAudio.fromMemory(Uint8List bytes, AudioContainer? format);
//   factory BackendAudio.fromFile(String path, AudioContainer? format);
//   int get sourceByteLength;
//   AudioInfo info();
//   AudioTags tags();
//   AudioCover? cover();
//   Waveform waveform(int buckets, WaveformMode mode, bool perChannel);
//   AudioPcm decode();
//   void dispose();
// }
// ```
export 'backend_native.dart'
    if (dart.library.js_interop) 'web/backend_web.dart';
