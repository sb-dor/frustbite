//! Streaming waveform: a bounded-memory, single-pass summary of a source for drawing.

use crate::decode::PacketDecoder;
use crate::error::FrustbiteErrorCode as Code;
use crate::probe::FrustbiteAudio;

/// Frames summarised per fine block.
pub(crate) const BLOCK: usize = 256;
/// Largest accepted bucket count.
pub(crate) const MAX_BUCKETS: u32 = 100_000;

/// How a bucket's amplitude is computed. Values are part of the ABI.
///
/// cbindgen:prefix-with-name
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum FrustbiteWaveformMode {
    /// Largest absolute sample value.
    Peak = 0,
    /// Root mean square.
    Rms = 1,
}

impl FrustbiteWaveformMode {
    /// Parses an ABI value.
    pub fn from_u32(value: u32) -> Result<Self, Code> {
        match value {
            0 => Ok(Self::Peak),
            1 => Ok(Self::Rms),
            _ => Err(Code::InvalidParameter),
        }
    }
}

/// Per-block, per-channel summary of the whole stream (block-major: `[block][channel]`).
struct Summary {
    channels: usize,
    /// `max |x|` per block and channel.
    peaks: Vec<f32>,
    /// `sum x^2` per block and channel.
    squares: Vec<f64>,
    /// Frames per block (the last block may be short).
    counts: Vec<u32>,
}

impl Summary {
    fn blocks(&self) -> usize {
        self.counts.len()
    }

    /// Reads the stream once, keeping only the per-block summary, never the PCM.
    fn collect(decoder: &mut PacketDecoder) -> Result<Self, Code> {
        let channels = decoder.channels();
        let mut summary = Self {
            channels,
            peaks: Vec::new(),
            squares: Vec::new(),
            counts: Vec::new(),
        };
        let mut peak = vec![0f32; channels];
        let mut square = vec![0f64; channels];
        let mut in_block = 0u32;
        loop {
            let chunk = match decoder.next_chunk() {
                Ok(Some(chunk)) => chunk,
                Ok(None) => break,
                // Like the info scan: a stream that breaks down midway still yields what was
                // decoded; only a source that yields nothing is an error.
                Err(code) if summary.counts.is_empty() && in_block == 0 => return Err(code),
                Err(_) => break,
            };
            for frame in chunk.chunks_exact(channels) {
                for (channel, &sample) in frame.iter().enumerate() {
                    // Non-finite samples would poison a block: count them as silence.
                    let sample = if sample.is_finite() { sample } else { 0.0 };
                    peak[channel] = peak[channel].max(sample.abs());
                    square[channel] += f64::from(sample) * f64::from(sample);
                }
                in_block += 1;
                if in_block as usize == BLOCK {
                    summary.push(&mut peak, &mut square, &mut in_block);
                }
            }
        }
        if in_block > 0 {
            summary.push(&mut peak, &mut square, &mut in_block);
        }
        Ok(summary)
    }

    fn push(&mut self, peak: &mut [f32], square: &mut [f64], in_block: &mut u32) {
        self.peaks.extend_from_slice(peak);
        self.squares.extend_from_slice(square);
        self.counts.push(*in_block);
        peak.fill(0.0);
        square.fill(0.0);
        *in_block = 0;
    }

    /// Maps the blocks onto `buckets`: bucket `i` covers blocks
    /// `[floor(i*B/buckets), max(floor((i+1)*B/buckets), floor(i*B/buckets)+1))`, clamped to
    /// `B`. With more buckets than blocks, neighbours repeat a block, so there is no gap.
    fn buckets(&self, buckets: usize, mode: FrustbiteWaveformMode, per_channel: bool) -> Vec<f32> {
        let series = if per_channel { self.channels } else { 1 };
        let mut out = vec![0f32; buckets * series];
        let blocks = self.blocks();
        if blocks == 0 {
            return out;
        }
        for bucket in 0..buckets {
            let lo = bucket * blocks / buckets;
            let hi = ((bucket + 1) * blocks / buckets).max(lo + 1).min(blocks);
            for s in 0..series {
                // Merged: every channel contributes; per channel: only channel `s`.
                let channels = if per_channel {
                    s..s + 1
                } else {
                    0..self.channels
                };
                let value = match mode {
                    FrustbiteWaveformMode::Peak => {
                        let mut peak = 0f32;
                        for block in lo..hi {
                            for c in channels.clone() {
                                peak = peak.max(self.peaks[block * self.channels + c]);
                            }
                        }
                        peak
                    }
                    FrustbiteWaveformMode::Rms => {
                        let (mut sum, mut count) = (0f64, 0u64);
                        for block in lo..hi {
                            for c in channels.clone() {
                                sum += self.squares[block * self.channels + c];
                                count += u64::from(self.counts[block]);
                            }
                        }
                        if count == 0 {
                            0.0
                        } else {
                            (sum / count as f64).sqrt() as f32
                        }
                    }
                };
                out[s * buckets + bucket] = value.clamp(0.0, 1.0);
            }
        }
        out
    }
}

impl FrustbiteAudio {
    /// Summarises the source into `buckets` amplitudes in [0, 1] (absolute full scale, not
    /// normalised), channel-major: all buckets of channel 0, then channel 1, and so on, or a
    /// single merged series when `per_channel` is false. Decodes the whole source in one pass
    /// and keeps one summary entry per 256 frames.
    ///
    /// A stream that ends early or breaks down midway yields a waveform of what was decoded;
    /// it is an error only when nothing could be decoded. A source without frames gives zeros.
    pub fn waveform(
        &self,
        buckets: u32,
        mode: FrustbiteWaveformMode,
        per_channel: bool,
    ) -> Result<Vec<f32>, Code> {
        if buckets == 0 || buckets > MAX_BUCKETS {
            return Err(Code::InvalidParameter);
        }
        let mut decoder = PacketDecoder::open(self)?;
        let summary = Summary::collect(&mut decoder)?;
        Ok(summary.buckets(buckets as usize, mode, per_channel))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../packages/frustbite/test/fixtures/"
    );

    fn wave(name: &str, buckets: u32, mode: FrustbiteWaveformMode, per_channel: bool) -> Vec<f32> {
        FrustbiteAudio::open_file(format!("{FIXTURES}{name}"), None)
            .unwrap()
            .waveform(buckets, mode, per_channel)
            .unwrap()
    }

    use FrustbiteWaveformMode::{Peak, Rms};

    #[test]
    fn waveform_wav_peak_is_half() {
        let values = wave("tone.wav", 100, Peak, false);
        assert_eq!(values.len(), 100);
        for v in values {
            assert!((0.49..=0.51).contains(&v), "{v}");
        }
    }

    #[test]
    fn waveform_rms_of_sine() {
        let expected = 0.5 / 2f32.sqrt();
        for v in wave("tone.wav", 100, Rms, false) {
            assert!((v - expected).abs() <= 0.01, "{v}");
        }
    }

    #[test]
    fn waveform_per_channel_len() {
        let values = wave("tone.wav", 100, Peak, true);
        assert_eq!(values.len(), 200);
        assert!(values.iter().all(|v| (0.49..=0.51).contains(v)));
    }

    #[cfg(feature = "flac")]
    #[test]
    fn waveform_silence_is_zero() {
        for mode in [Peak, Rms] {
            let values = wave("silence.flac", 50, mode, false);
            assert_eq!(values.len(), 50);
            assert!(values.iter().all(|&v| v == 0.0));
        }
    }

    #[test]
    fn waveform_more_buckets_than_frames() {
        for mode in [Peak, Rms] {
            let values = wave("click.wav", 1000, mode, false);
            assert_eq!(values.len(), 1000);
            assert!(
                values
                    .iter()
                    .all(|v| v.is_finite() && (0.0..=1.0).contains(v))
            );
        }
    }

    #[cfg(feature = "opus")]
    #[test]
    fn waveform_covers_file_without_duration() {
        let values = wave("tone.webm", 100, Peak, false);
        assert!(values[99] > 0.4, "{}", values[99]);
    }

    #[test]
    fn waveform_zero_buckets_invalid() {
        let audio = FrustbiteAudio::open_file(format!("{FIXTURES}tone.wav"), None).unwrap();
        assert_eq!(audio.waveform(0, Peak, false), Err(Code::InvalidParameter));
        assert_eq!(
            audio.waveform(MAX_BUCKETS + 1, Peak, false),
            Err(Code::InvalidParameter)
        );
        assert!(audio.waveform(MAX_BUCKETS, Peak, false).is_ok());
    }

    #[test]
    fn waveform_mode_from_u32() {
        assert_eq!(FrustbiteWaveformMode::from_u32(1), Ok(Rms));
        assert_eq!(
            FrustbiteWaveformMode::from_u32(2),
            Err(Code::InvalidParameter)
        );
    }

    #[test]
    fn waveform_channels_are_separate() {
        // tone.wav: 440 Hz left, 880 Hz right, same amplitude, so both channels peak alike
        // while merged Rms equals each channel's Rms.
        let merged = wave("tone.wav", 10, Rms, false);
        let split = wave("tone.wav", 10, Rms, true);
        for i in 0..10 {
            assert!((merged[i] - split[i]).abs() < 0.01);
            assert!((merged[i] - split[10 + i]).abs() < 0.01);
        }
    }

    #[test]
    fn waveform_empty_source_is_zeros() {
        let audio = FrustbiteAudio::open_memory(&crate::ffi::tests::empty_wav(), None).unwrap();
        assert_eq!(audio.waveform(8, Rms, true).unwrap(), vec![0.0; 8]);
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn waveform_truncated_mp3_covers_what_decodes() {
        let values = wave("truncated.mp3", 20, Peak, false);
        assert!(values.iter().any(|&v| v > 0.0));
    }

    #[cfg(all(
        feature = "mp3",
        feature = "aac",
        feature = "vorbis",
        feature = "opus",
        feature = "flac"
    ))]
    #[test]
    fn waveform_lossy_fixtures_stay_in_range() {
        for name in ["tone.mp3", "tone.m4a", "tone.ogg", "tone.opus", "tone.flac"] {
            let values = wave(name, 64, Peak, true);
            assert_eq!(values.len(), 128, "{name}");
            assert!(values.iter().all(|v| (0.0..=1.0).contains(v)), "{name}");
            assert!(values[32] > 0.4, "{name}");
        }
    }
}
