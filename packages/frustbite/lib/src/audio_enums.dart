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
///
/// Exhaustive switches: adding a value to either side is a compile error here.
extension AudioContainerWire on AudioContainer {
  int get wireValue => switch (this) {
    AudioContainer.mp3 => FrustbiteContainer.mp3,
    AudioContainer.mp4 => FrustbiteContainer.mp4,
    AudioContainer.flac => FrustbiteContainer.flac,
    AudioContainer.ogg => FrustbiteContainer.ogg,
    AudioContainer.wav => FrustbiteContainer.wav,
    AudioContainer.mkv => FrustbiteContainer.mkv,
    AudioContainer.adts => FrustbiteContainer.adts,
  }.value;

  static AudioContainer fromWire(int value) =>
      switch (FrustbiteContainer.fromValue(value)) {
        FrustbiteContainer.mp3 => AudioContainer.mp3,
        FrustbiteContainer.mp4 => AudioContainer.mp4,
        FrustbiteContainer.flac => AudioContainer.flac,
        FrustbiteContainer.ogg => AudioContainer.ogg,
        FrustbiteContainer.wav => AudioContainer.wav,
        FrustbiteContainer.mkv => AudioContainer.mkv,
        FrustbiteContainer.adts => AudioContainer.adts,
      };
}

extension AudioCodecWire on AudioCodec {
  int get wireValue => switch (this) {
    AudioCodec.mp3 => FrustbiteCodec.mp3,
    AudioCodec.aac => FrustbiteCodec.aac,
    AudioCodec.alac => FrustbiteCodec.alac,
    AudioCodec.flac => FrustbiteCodec.flac,
    AudioCodec.vorbis => FrustbiteCodec.vorbis,
    AudioCodec.opus => FrustbiteCodec.opus,
    AudioCodec.pcm => FrustbiteCodec.pcm,
  }.value;

  static AudioCodec fromWire(int value) =>
      switch (FrustbiteCodec.fromValue(value)) {
        FrustbiteCodec.mp3 => AudioCodec.mp3,
        FrustbiteCodec.aac => AudioCodec.aac,
        FrustbiteCodec.alac => AudioCodec.alac,
        FrustbiteCodec.flac => AudioCodec.flac,
        FrustbiteCodec.vorbis => AudioCodec.vorbis,
        FrustbiteCodec.opus => AudioCodec.opus,
        FrustbiteCodec.pcm => AudioCodec.pcm,
      };
}

extension WaveformModeWire on WaveformMode {
  int get wireValue => switch (this) {
    WaveformMode.peak => FrustbiteWaveformMode.peak,
    WaveformMode.rms => FrustbiteWaveformMode.rms,
  }.value;

  static WaveformMode fromWire(int value) =>
      switch (FrustbiteWaveformMode.fromValue(value)) {
        FrustbiteWaveformMode.peak => WaveformMode.peak,
        FrustbiteWaveformMode.rms => WaveformMode.rms,
      };
}
