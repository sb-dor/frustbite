//! Decoding: a reusable packet loop and whole-source decoding to interleaved f32.

use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatReader;
use symphonia::core::units::Duration;

use crate::codecs;
use crate::error::FrustbiteErrorCode as Code;
use crate::probe::{FrustbiteAudio, MAX_CONSECUTIVE_DECODE_ERRORS, map_error, open_reader};

/// A fully decoded source.
#[derive(Debug)]
pub struct Decoded {
    /// Interleaved samples in [-1, 1]; empty when the source holds no audio frames.
    pub samples: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Channel count.
    pub channels: u32,
}

/// Reads packets of the selected track and yields them decoded, one packet at a time, as
/// interleaved f32. Every consumer (full decode, waveform) drives this same loop.
///
/// Recoverable errors skip the packet; too many in a row, or an unrecoverable error, end the
/// loop with `Err`. A clean end of stream, or a truncated one (unexpected EOF), ends it with
/// `Ok(None)`.
pub struct PacketDecoder {
    reader: Box<dyn FormatReader + 'static>,
    decoder: Box<dyn AudioDecoder + 'static>,
    track_id: u32,
    channels: usize,
    sample_rate: u32,
    /// Frames still to drop from the start of the output (Opus pre-skip).
    skip_frames: u64,
    /// The decoder does not trim by packet (`trim_start`/`trim_end`) itself.
    trim_packets: bool,
    /// MP3 without a LAME tag: its packet trims are guesses, so they are cleared.
    clear_trims: bool,
    consecutive_errors: u32,
    chunk: Vec<f32>,
}

impl PacketDecoder {
    /// Opens a fresh reader and decoder for the audio track chosen at probe time.
    pub fn open(audio: &FrustbiteAudio) -> Result<Self, Code> {
        let probed = audio.probed();
        let reader = open_reader(audio.source(), audio.hint())?;
        let track = reader
            .tracks()
            .iter()
            .find(|track| track.id == probed.track_id)
            .ok_or(Code::DecodingError)?;
        let params = track
            .codec_params
            .as_ref()
            .and_then(|params| params.audio())
            .ok_or(Code::UnsupportedFormat)?;
        let decoder = codecs::registry()
            .make_audio_decoder(params, &AudioDecoderOptions::default())
            .map_err(|error| map_error(&error))?;
        Ok(Self {
            reader,
            decoder,
            track_id: probed.track_id,
            channels: probed.channels as usize,
            sample_rate: probed.sample_rate,
            skip_frames: probed.pre_skip,
            // MP3 and Vorbis trim inside the decoder; our Opus decoder (the only one with a
            // pre-skip) leaves all trimming to the caller. The rest never get trims.
            trim_packets: audio.is_opus(),
            clear_trims: audio.is_mp3() && !probed.mp3_trims_trusted,
            consecutive_errors: 0,
            chunk: Vec::new(),
        })
    }

    /// Sample rate of the decoded output.
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Channel count of the decoded output.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Decodes the next non-empty packet. The slice is valid until the next call and holds
    /// whole frames, interleaved.
    pub fn next_chunk(&mut self) -> Result<Option<&[f32]>, Code> {
        loop {
            let packet = match self.reader.next_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) => return Ok(None),
                Err(error) => {
                    if self.recoverable(&error)? {
                        continue;
                    }
                    return Ok(None);
                }
            };
            if packet.track_id != self.track_id {
                continue;
            }
            let mut packet = packet;
            if self.clear_trims {
                packet.trim_start = Duration::ZERO;
                packet.trim_end = Duration::ZERO;
            }
            let decoded = match self.decoder.decode(&packet) {
                Ok(decoded) => decoded,
                Err(error) => {
                    if self.recoverable(&error)? {
                        continue;
                    }
                    return Ok(None);
                }
            };
            self.consecutive_errors = 0;
            if decoded.spec().channels().count() != self.channels {
                return Err(Code::DecodingError);
            }

            let frames = decoded.frames();
            let (mut start, mut end) = (0usize, frames);
            if self.trim_packets {
                start = usize::try_from(packet.trim_start.get()).unwrap_or(usize::MAX);
                end = frames
                    .saturating_sub(usize::try_from(packet.trim_end.get()).unwrap_or(usize::MAX));
            }
            let skip = usize::try_from(self.skip_frames).unwrap_or(usize::MAX);
            let skipped = skip.min(end.saturating_sub(start));
            start += skipped;
            self.skip_frames -= skipped as u64;
            if start >= end {
                continue;
            }
            decoded
                .slice(start..end)
                .copy_to_vec_interleaved(&mut self.chunk);
            return Ok(Some(&self.chunk));
        }
    }

    /// `Ok(true)`: skip and go on; `Ok(false)`: the stream ended (truncated); `Err`: give up.
    fn recoverable(&mut self, error: &SymphoniaError) -> Result<bool, Code> {
        match error {
            SymphoniaError::IoError(io) if io.kind() == std::io::ErrorKind::UnexpectedEof => {
                Ok(false)
            }
            SymphoniaError::DecodeError(_) => {
                self.consecutive_errors += 1;
                if self.consecutive_errors >= MAX_CONSECUTIVE_DECODE_ERRORS {
                    Err(Code::DecodingError)
                } else {
                    Ok(true)
                }
            }
            other => Err(map_error(other)),
        }
    }
}

impl FrustbiteAudio {
    /// Decodes the whole source to interleaved f32 at its native rate and channel count.
    pub fn decode(&self) -> Result<Decoded, Code> {
        let probed = self.probed();
        let channels = probed.channels;
        let mut samples = Vec::new();
        if let Some(frames) = probed.known_frames
            && let Ok(count) = usize::try_from(frames.saturating_mul(u64::from(channels)))
        {
            // A lying header must not abort the process: best-effort reservation only.
            let _ = samples.try_reserve_exact(count);
        }
        let mut decoder = PacketDecoder::open(self)?;
        let sample_rate = decoder.sample_rate();
        while let Some(chunk) = decoder.next_chunk()? {
            samples.extend_from_slice(chunk);
        }
        Ok(Decoded {
            samples,
            sample_rate,
            channels,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../packages/frustbite/test/fixtures/"
    );

    fn decode(name: &str) -> Result<Decoded, Code> {
        FrustbiteAudio::open_file(format!("{FIXTURES}{name}"), None)?.decode()
    }

    #[cfg(any(
        all(feature = "mp3", feature = "aac", feature = "vorbis", feature = "opus"),
        all(feature = "flac", feature = "alac")
    ))]
    /// Squared magnitude of `signal` at `freq` (Goertzel).
    fn goertzel(signal: impl Iterator<Item = f32>, rate: f64, freq: f64) -> f64 {
        let coeff = 2.0 * (2.0 * std::f64::consts::PI * freq / rate).cos();
        let (mut s1, mut s2) = (0.0f64, 0.0f64);
        for x in signal {
            let s0 = f64::from(x) + coeff * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        s1 * s1 + s2 * s2 - coeff * s1 * s2
    }

    #[cfg(any(
        all(feature = "mp3", feature = "aac", feature = "vorbis", feature = "opus"),
        all(feature = "flac", feature = "alac")
    ))]
    fn channel(decoded: &Decoded, index: usize) -> impl Iterator<Item = f32> + '_ {
        decoded
            .samples
            .iter()
            .skip(index)
            .step_by(decoded.channels as usize)
            .copied()
    }

    #[cfg(any(
        all(feature = "mp3", feature = "aac", feature = "vorbis", feature = "opus"),
        all(feature = "flac", feature = "alac")
    ))]
    fn assert_stereo_tone(name: &str, decoded: &Decoded) {
        assert_eq!(decoded.channels, 2, "{name}");
        let rate = f64::from(decoded.sample_rate);
        let energy = |ch, freq| goertzel(channel(decoded, ch), rate, freq);
        assert!(energy(0, 440.0) > 20.0 * energy(0, 880.0), "{name}: left");
        assert!(energy(1, 880.0) > 20.0 * energy(1, 440.0), "{name}: right");
    }

    #[test]
    fn decode_wav_exact() {
        let decoded = decode("tone.wav").unwrap();
        assert_eq!(decoded.sample_rate, 44_100);
        assert_eq!(decoded.channels, 2);
        assert_eq!(decoded.samples.len(), 132_300 * 2);
        let expected = 0.5 * (2.0 * std::f64::consts::PI * 440.0 * 100.0 / 44_100.0).sin();
        let actual = f64::from(decoded.samples[100 * 2]);
        assert!(
            (actual - expected).abs() <= 1.0 / 32_768.0,
            "{actual} {expected}"
        );
        assert!(decoded.samples.iter().all(|s| s.abs() <= 1.0));
    }

    #[cfg(all(feature = "mp3", feature = "aac", feature = "vorbis", feature = "opus"))]
    #[test]
    fn decode_lossy_fixtures_have_tone() {
        for name in ["tone.mp3", "tone.m4a", "tone.ogg", "tone.opus", "tone.webm"] {
            let decoded = decode(name).unwrap();
            assert_stereo_tone(name, &decoded);
        }
    }

    #[cfg(all(feature = "flac", feature = "alac"))]
    #[test]
    fn decode_lossless_fixtures_have_tone() {
        for name in ["tone.flac", "tone_alac.m4a"] {
            assert_stereo_tone(name, &decode(name).unwrap());
        }
    }

    #[cfg(feature = "flac")]
    #[test]
    fn decode_flac_matches_wav() {
        let wav = decode("tone.wav").unwrap();
        let flac = decode("tone.flac").unwrap();
        assert_eq!(flac.samples.len(), wav.samples.len());
        let worst = wav
            .samples
            .iter()
            .zip(&flac.samples)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0f32, f32::max);
        // The FLAC is 24-bit, so it only matches the 16-bit WAV to within one 16-bit step.
        assert!(worst <= 1.0 / 32_768.0, "{worst}");
    }

    #[cfg(any(
        all(
            feature = "mp3",
            feature = "flac",
            feature = "alac",
            feature = "vorbis",
            feature = "opus"
        ),
        all(feature = "aac", feature = "opus")
    ))]
    fn decoded_frames(decoded: &Decoded) -> u64 {
        (decoded.samples.len() / decoded.channels as usize) as u64
    }

    #[cfg(all(
        feature = "mp3",
        feature = "flac",
        feature = "alac",
        feature = "vorbis",
        feature = "opus"
    ))]
    #[test]
    fn decode_frames_match_info() {
        for name in [
            "tone.wav",
            "tone.flac",
            "tone.mp3",
            "tone_vbr_noxing.mp3",
            "tone_alac.m4a",
            "tone.ogg",
            "tone.opus",
        ] {
            let audio = FrustbiteAudio::open_file(format!("{FIXTURES}{name}"), None).unwrap();
            let info = audio.info().unwrap();
            let decoded = audio.decode().unwrap();
            assert_eq!(decoded_frames(&decoded), info.total_frames, "{name}");
        }
    }

    #[cfg(all(feature = "aac", feature = "opus"))]
    #[test]
    fn decode_frames_differ_from_info_by_a_documented_tolerance() {
        // AAC in MP4: info uses the mdhd duration without the edit list, so it includes the
        // 1024-frame encoder priming; decoding yields priming plus padding, so the two differ
        // by up to one packet.
        // WebM Opus: no end trim exists (Symphonia drops DiscardPadding), so decoding keeps the
        // tail padding, and the duration in the info comes from millisecond timestamps.
        for (name, tolerance) in [("tone.m4a", 1024), ("tone.webm", 960)] {
            let audio = FrustbiteAudio::open_file(format!("{FIXTURES}{name}"), None).unwrap();
            let info = audio.info().unwrap();
            let frames = decoded_frames(&audio.decode().unwrap());
            assert!(
                frames.abs_diff(info.total_frames) <= tolerance,
                "{name}: {frames}"
            );
        }
    }

    #[cfg(feature = "opus")]
    #[test]
    fn decode_opus_drops_preskip() {
        for name in ["tone.opus", "tone.webm"] {
            let decoded = decode(name).unwrap();
            assert_eq!(decoded.sample_rate, 48_000);
            let frames = decoded.samples.len() / 2;
            assert!(frames.abs_diff(144_000) <= 960, "{name}: {frames}");
        }
        // Ogg Opus also trims the end exactly, like ffmpeg.
        assert_eq!(decode("tone.opus").unwrap().samples.len(), 144_000 * 2);
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn decode_truncated_mp3_returns_error_or_partial() {
        match decode("truncated.mp3") {
            Ok(decoded) => {
                let frames = decoded.samples.len() / decoded.channels as usize;
                assert!(
                    frames as f64 >= 1.5 * f64::from(decoded.sample_rate),
                    "{frames}"
                );
            }
            Err(code) => assert_eq!(code, Code::DecodingError),
        }
    }

    #[cfg(feature = "flac")]
    #[test]
    fn decode_silence_is_zero() {
        let decoded = decode("silence.flac").unwrap();
        assert!(!decoded.samples.is_empty());
        assert!(decoded.samples.iter().all(|&s| s == 0.0));
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn decode_memory_matches_file() {
        let bytes = std::fs::read(format!("{FIXTURES}tone.mp3")).unwrap();
        let memory = FrustbiteAudio::open_memory(&bytes, None)
            .unwrap()
            .decode()
            .unwrap();
        assert_eq!(memory.samples, decode("tone.mp3").unwrap().samples);
    }
}
