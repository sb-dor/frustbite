import 'enums.dart';

/// Container format of an audio source.
enum AudioContainer { mp3, mp4, flac, ogg, wav, mkv, adts }

/// Codec of the audio stream.
enum AudioCodec { mp3, aac, alac, flac, vorbis, opus, pcm }

/// How a waveform bucket's amplitude is computed.
enum WaveformMode {
  /// Largest absolute sample value in the bucket.
  peak,

  /// Root mean square of the bucket.
  rms,
}

/// Mapping between the public enums and the ABI values. Not exported.
extension AudioContainerWire on AudioContainer {
  int get wireValue => FrustbiteContainer.values.byName(name).value;

  static AudioContainer fromWire(int value) =>
      AudioContainer.values.byName(FrustbiteContainer.fromValue(value).name);
}

extension AudioCodecWire on AudioCodec {
  int get wireValue => FrustbiteCodec.values.byName(name).value;

  static AudioCodec fromWire(int value) =>
      AudioCodec.values.byName(FrustbiteCodec.fromValue(value).name);
}

extension WaveformModeWire on WaveformMode {
  int get wireValue => FrustbiteWaveformMode.values.byName(name).value;
}
