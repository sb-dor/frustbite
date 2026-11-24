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

/// A source of decoded interleaved chunks; `PacketDecoder` in production, a mock in tests.
trait ChunkSource {
    fn channels(&self) -> usize;
    fn next_chunk(&mut self) -> Result<Option<&[f32]>, Code>;
}

impl ChunkSource for PacketDecoder {
    fn channels(&self) -> usize {
        PacketDecoder::channels(self)
    }

    fn next_chunk(&mut self) -> Result<Option<&[f32]>, Code> {
        PacketDecoder::next_chunk(self)
    }
}

/// Per-block, per-channel summary of the whole stream, for one mode.
///
/// Memory: one `f32` per block and channel, i.e. `4 * channels` bytes per 256 frames
/// (8 bytes for stereo: about 5 MB for an hour at 44.1 kHz), plus the accumulators.
struct Summary {
    channels: usize,
    mode: FrustbiteWaveformMode,
    /// Block-major `[block][channel]`: `max |x|` for Peak, `sum x^2` for Rms (an `f32` is
    /// precise enough over at most 256 samples).
    values: Vec<f32>,
    /// Frames in the last block; every other block holds exactly `BLOCK`. 0 without blocks.
    last_frames: usize,
}

/// Blocks `[lo, hi)` of bucket `bucket` out of `buckets`, for `blocks` blocks:
/// `[floor(i*B/n), max(floor((i+1)*B/n), floor(i*B/n)+1))` clamped to `B`. The products are
/// computed in `u64`: `usize` is 32-bit on wasm32 and they exceed `u32::MAX` for long files.
fn bucket_range(bucket: usize, buckets: usize, blocks: usize) -> (usize, usize) {
    let edge = |i: usize| (i as u64 * blocks as u64 / buckets as u64) as usize;
    let lo = edge(bucket);
    (lo, edge(bucket + 1).max(lo + 1).min(blocks))
}

impl Summary {
    fn blocks(&self) -> usize {
        self.values.len() / self.channels
    }

    /// Reads the stream once, keeping only the per-block summary, never the PCM.
    /// `expected_frames` (from the container, if known) only sizes a best-effort reservation.
    fn collect(
        source: &mut impl ChunkSource,
        mode: FrustbiteWaveformMode,
        expected_frames: Option<u64>,
    ) -> Result<Self, Code> {
        let channels = source.channels();
        let mut summary = Self {
            channels,
            mode,
            values: Vec::new(),
            last_frames: 0,
        };
        if let Some(frames) = expected_frames {
            // A lying header must not abort the process: best-effort, capped (64 MB).
            let blocks = frames / BLOCK as u64 + 1;
            let wanted = blocks.saturating_mul(channels as u64).min(1 << 24);
            let _ = summary.values.try_reserve(wanted as usize);
        }
        let mut acc = vec![0f32; channels];
        let mut in_block = 0usize;
        loop {
            let chunk = match source.next_chunk() {
                Ok(Some(chunk)) => chunk,
                Ok(None) => break,
                // Like the info scan: a stream that breaks down midway still yields what was
                // decoded; only a source that yields nothing is an error.
                Err(code) if summary.values.is_empty() && in_block == 0 => return Err(code),
                Err(_) => break,
            };
            for frame in chunk.chunks_exact(channels) {
                for (slot, &sample) in acc.iter_mut().zip(frame) {
                    // Non-finite samples would poison a block: count them as silence.
                    let sample = if sample.is_finite() { sample } else { 0.0 };
                    match mode {
                        FrustbiteWaveformMode::Peak => *slot = slot.max(sample.abs()),
                        FrustbiteWaveformMode::Rms => *slot += sample * sample,
                    }
                }
                in_block += 1;
                if in_block == BLOCK {
                    summary.values.extend_from_slice(&acc);
                    acc.fill(0.0);
                    in_block = 0;
                    summary.last_frames = BLOCK;
                }
            }
        }
        if in_block > 0 {
            summary.values.extend_from_slice(&acc);
            summary.last_frames = in_block;
        }
        Ok(summary)
    }

    /// Frames covered by blocks `[lo, hi)`.
    fn frames(&self, lo: usize, hi: usize) -> u64 {
        let mut frames = ((hi - lo) * BLOCK) as u64;
        if hi == self.blocks() {
            frames -= (BLOCK - self.last_frames) as u64;
        }
        frames
    }

    /// Maps the blocks onto `buckets` (see `bucket_range`). With more buckets than blocks,
    /// neighbours repeat a block, so there is no gap.
    fn buckets(&self, buckets: usize, per_channel: bool) -> Vec<f32> {
        let series = if per_channel { self.channels } else { 1 };
        let mut out = vec![0f32; buckets * series];
        let blocks = self.blocks();
        if blocks == 0 {
            return out;
        }
        for bucket in 0..buckets {
            let (lo, hi) = bucket_range(bucket, buckets, blocks);
            let frames = self.frames(lo, hi);
            for s in 0..series {
                // Merged: every channel contributes; per channel: only channel `s`.
                let channels = if per_channel {
                    s..s + 1
                } else {
                    0..self.channels
                };
                let value = match self.mode {
                    FrustbiteWaveformMode::Peak => {
                        let mut peak = 0f32;
                        for block in lo..hi {
                            for c in channels.clone() {
                                peak = peak.max(self.values[block * self.channels + c]);
                            }
                        }
                        peak
                    }
                    FrustbiteWaveformMode::Rms => {
                        let mut sum = 0f64;
                        for block in lo..hi {
                            for c in channels.clone() {
                                sum += f64::from(self.values[block * self.channels + c]);
                            }
                        }
                        let count = frames * channels.len() as u64;
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
        let expected = self.probed().known_frames;
        let summary = Summary::collect(&mut decoder, mode, expected)?;
        Ok(summary.buckets(buckets as usize, per_channel))
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

    #[cfg(feature = "wav")]
    #[test]
    fn waveform_wav_peak_is_half() {
        let values = wave("tone.wav", 100, Peak, false);
        assert_eq!(values.len(), 100);
        for v in values {
            assert!((0.49..=0.51).contains(&v), "{v}");
        }
    }

    #[cfg(feature = "wav")]
    #[test]
    fn waveform_rms_of_sine() {
        let expected = 0.5 / 2f32.sqrt();
        for v in wave("tone.wav", 100, Rms, false) {
            assert!((v - expected).abs() <= 0.01, "{v}");
        }
    }

    #[cfg(feature = "wav")]
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

    #[cfg(feature = "wav")]
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

    #[cfg(feature = "wav")]
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

    #[cfg(feature = "wav")]
    #[test]
    fn waveform_channels_are_separate() {
        // tone.wav: 440 Hz left, 880 Hz right, same amplitude, so the merged Rms equals
        // each channel's Rms.
        let merged = wave("tone.wav", 10, Rms, false);
        let split = wave("tone.wav", 10, Rms, true);
        for i in 0..10 {
            assert!((merged[i] - split[i]).abs() < 0.01);
            assert!((merged[i] - split[10 + i]).abs() < 0.01);
        }
    }

    #[cfg(feature = "wav")]
    #[test]
    fn waveform_empty_source_is_zeros() {
        let audio = FrustbiteAudio::open_memory(&crate::ffi::tests::empty_wav(), None).unwrap();
        assert_eq!(audio.waveform(8, Rms, true).unwrap(), vec![0.0; 8]);
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn waveform_truncated_mp3_covers_what_decodes() {
        let values = wave("truncated.mp3", 20, Peak, false);
        // The whole decoded part is the tone (amplitude 0.5), so the first half is loud.
        assert!(values[..10].iter().all(|&v| v > 0.4), "{values:?}");
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

    #[test]
    fn bucket_ranges_cover_blocks_without_gaps_for_large_inputs() {
        // 700_000 blocks x 100_000 buckets overflows u32 (and 32-bit usize on wasm32).
        for (blocks, buckets) in [
            (700_000, 100_000),
            (1_000_000, 99_999),
            (5, 100_000),
            (1, 7),
        ] {
            let mut previous = (0usize, 0usize);
            for bucket in 0..buckets {
                let (lo, hi) = bucket_range(bucket, buckets, blocks);
                assert!(lo < hi && hi <= blocks, "{bucket}: {lo}..{hi}");
                if bucket == 0 {
                    assert_eq!(lo, 0);
                } else {
                    // Monotonic and gap-free: never starts past the previous end, never moves back.
                    assert!(lo >= previous.0 && hi >= previous.1, "{bucket}");
                    assert!(lo <= previous.1, "gap at {bucket}");
                }
                previous = (lo, hi);
            }
            assert_eq!(previous.1, blocks);
        }
    }

    #[test]
    fn summary_maps_a_large_hand_built_summary() {
        let blocks = 700_000;
        let summary = Summary {
            channels: 1,
            mode: Peak,
            values: (0..blocks).map(|b| (b % 1000) as f32 / 1000.0).collect(),
            last_frames: BLOCK,
        };
        let out = summary.buckets(100_000, false);
        assert_eq!(out.len(), 100_000);
        assert!(out.iter().all(|v| (0.0..=1.0).contains(v)));
        // Every bucket covers 7 blocks of an in-range ramp: its max is the ramp value.
        assert!(out.iter().any(|&v| v > 0.9));
    }

    /// Yields the given chunks, then the final result.
    struct Mock {
        chunks: Vec<Vec<f32>>,
        end: Result<(), Code>,
        next: usize,
    }

    impl ChunkSource for Mock {
        fn channels(&self) -> usize {
            1
        }

        fn next_chunk(&mut self) -> Result<Option<&[f32]>, Code> {
            let index = self.next;
            self.next += 1;
            match self.chunks.get(index) {
                Some(chunk) => Ok(Some(chunk)),
                None => self.end.map(|()| None),
            }
        }
    }

    #[test]
    fn decode_failure_after_data_keeps_what_was_decoded() {
        // What the packet loop reports after too many consecutive bad packets.
        let mut mock = Mock {
            chunks: vec![vec![0.5; 1024]],
            end: Err(Code::DecodingError),
            next: 0,
        };
        let summary = Summary::collect(&mut mock, Peak, None).unwrap();
        assert_eq!(summary.blocks(), 4);
        assert!(summary.buckets(8, false).iter().all(|&v| v == 0.5));
    }

    #[test]
    fn decode_failure_with_nothing_decoded_is_an_error() {
        let mut mock = Mock {
            chunks: vec![],
            end: Err(Code::DecodingError),
            next: 0,
        };
        assert_eq!(
            Summary::collect(&mut mock, Peak, None).err(),
            Some(Code::DecodingError)
        );
    }

    #[test]
    fn partial_last_block_counts_only_its_frames() {
        let mut mock = Mock {
            chunks: vec![vec![0.5; BLOCK + 10]],
            end: Ok(()),
            next: 0,
        };
        let summary = Summary::collect(&mut mock, Rms, Some(u64::MAX)).unwrap();
        assert_eq!((summary.blocks(), summary.last_frames), (2, 10));
        assert!(
            summary
                .buckets(1, false)
                .iter()
                .all(|v| (v - 0.5).abs() < 1e-6)
        );
    }
}
