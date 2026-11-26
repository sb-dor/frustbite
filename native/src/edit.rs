//! Editing: a list of operations applied in order to the decoded PCM of a source.
//!
//! The Dart side sends the list as JSON (see `Op`), so new operations never change a C
//! signature. Everything happens in memory: the source and every extra source are decoded
//! whole (streaming arrives with stage 4).

use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Resampler};
use serde::Deserialize;

use crate::decode::Decoded;
use crate::error::FrustbiteErrorCode as Code;
use crate::probe::FrustbiteAudio;

/// Highest sample rate `resample` accepts, as a target or a source.
pub(crate) const MAX_SAMPLE_RATE: u32 = 768_000;

/// Lowest source rate `resample` accepts. The FFT resampler's buffers grow with
/// `target / source`, so a header claiming a few Hz would allocate gigabytes.
pub(crate) const MIN_SOURCE_SAMPLE_RATE: u32 = 1_000;

/// Most samples a result may hold: what a 16-bit WAV (4 GiB of data) can carry. Checked
/// before an operation grows the buffer, so an impossible edit fails fast instead of
/// committing the memory first.
pub(crate) const MAX_SAMPLES: usize = (u32::MAX / 2) as usize;

/// `InvalidParameter` when `samples` exceeds `MAX_SAMPLES`.
fn check_len(samples: usize) -> Result<(), Code> {
    if samples > MAX_SAMPLES {
        Err(Code::InvalidParameter)
    } else {
        Ok(())
    }
}

/// One editing step. JSON: an object with `"op"` set to the snake_case variant name and the
/// fields below; unknown operations or fields are rejected.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Op {
    /// Keeps `[start_us, end_us)`; `end_us` absent means to the end.
    Trim { start_us: u64, end_us: Option<u64> },
    /// Multiplies by `10^(db/20)`.
    Gain { db: f64 },
    /// Scales so the peak becomes `peak_db` dBFS (`<= 0`). Silence is left alone.
    Normalize { peak_db: f64 },
    /// Linear fade from silence over the first `duration_us`.
    FadeIn { duration_us: u64 },
    /// Linear fade to silence over the last `duration_us`.
    FadeOut { duration_us: u64 },
    /// Converts to `sample_rate` Hz (1..=768000). The source rate must be in
    /// 1000..=768000 (`UnsupportedFormat` otherwise).
    Resample { sample_rate: u32 },
    /// Averages every channel into one. (Empty struct variants, so `deny_unknown_fields`
    /// applies to them too.)
    ToMono {},
    /// Mono is duplicated; more than two channels keep the first two.
    ToStereo {},
    /// Drops leading and trailing frames whose every channel is below `threshold_db` (`<= 0`).
    TrimSilence { threshold_db: f64 },
    /// Appends `sources[source]`, converted to the current format, with an equal-power
    /// crossfade of `crossfade_us`.
    Append { source: usize, crossfade_us: u64 },
    /// Adds `sources[source]`, converted to the current format and scaled by `gain_db`,
    /// starting at `offset_us`. No limiter: the sum can exceed full scale.
    Mix {
        source: usize,
        gain_db: f64,
        offset_us: u64,
    },
}

/// Parses and checks an operation list. `sources` is how many extra sources the call has.
pub fn parse_ops(json: &[u8], sources: usize) -> Result<Vec<Op>, Code> {
    if json.is_empty() {
        return Ok(Vec::new());
    }
    let ops: Vec<Op> = serde_json::from_slice(json).map_err(|_| Code::InvalidParameter)?;
    for op in &ops {
        validate(op, sources)?;
    }
    Ok(ops)
}

fn validate(op: &Op, sources: usize) -> Result<(), Code> {
    let ok = match *op {
        Op::Trim { start_us, end_us } => end_us.is_none_or(|end| start_us <= end),
        Op::Gain { db } => db.is_finite(),
        Op::Normalize { peak_db } => peak_db.is_finite() && peak_db <= 0.0,
        Op::FadeIn { .. } | Op::FadeOut { .. } | Op::ToMono {} | Op::ToStereo {} => true,
        Op::Resample { sample_rate } => (1..=MAX_SAMPLE_RATE).contains(&sample_rate),
        Op::TrimSilence { threshold_db } => threshold_db.is_finite() && threshold_db <= 0.0,
        Op::Append { source, .. } => source < sources,
        Op::Mix {
            source, gain_db, ..
        } => source < sources && gain_db.is_finite(),
    };
    if ok {
        Ok(())
    } else {
        Err(Code::InvalidParameter)
    }
}

/// `10^(db/20)`.
fn db_to_amplitude(db: f64) -> f32 {
    10f64.powf(db / 20.0) as f32
}

/// Frames in `us` microseconds at `rate`, rounded to the nearest frame.
fn us_to_frames(us: u64, rate: u32) -> usize {
    let frames = (u128::from(us) * u128::from(rate) + 500_000) / 1_000_000;
    usize::try_from(frames).unwrap_or(usize::MAX)
}

impl Decoded {
    fn channel_count(&self) -> usize {
        self.channels as usize
    }

    /// Frames per channel.
    pub fn frames(&self) -> usize {
        self.samples.len() / self.channel_count().max(1)
    }

    fn scale(&mut self, factor: f32) {
        if factor != 1.0 {
            self.samples.iter_mut().for_each(|x| *x *= factor);
        }
    }

    fn trim(&mut self, start_us: u64, end_us: Option<u64>) {
        let frames = self.frames();
        let end = end_us
            .map_or(frames, |end| us_to_frames(end, self.sample_rate))
            .min(frames);
        let start = us_to_frames(start_us, self.sample_rate).min(end);
        self.keep_frames(start, end);
    }

    fn keep_frames(&mut self, start: usize, end: usize) {
        let ch = self.channel_count();
        self.samples.truncate(end * ch);
        self.samples.drain(..start * ch);
    }

    fn normalize(&mut self, peak_db: f64) {
        let peak = self.samples.iter().fold(0.0f32, |max, x| max.max(x.abs()));
        if peak > 0.0 && peak.is_finite() {
            self.scale(db_to_amplitude(peak_db) / peak);
        }
    }

    fn fade_in(&mut self, duration_us: u64) {
        let ch = self.channel_count();
        let n = us_to_frames(duration_us, self.sample_rate).min(self.frames());
        for (i, frame) in self.samples.chunks_exact_mut(ch).take(n).enumerate() {
            let gain = i as f32 / n as f32;
            frame.iter_mut().for_each(|x| *x *= gain);
        }
    }

    fn fade_out(&mut self, duration_us: u64) {
        let ch = self.channel_count();
        let frames = self.frames();
        let n = us_to_frames(duration_us, self.sample_rate).min(frames);
        for (i, frame) in self.samples[(frames - n) * ch..]
            .chunks_exact_mut(ch)
            .enumerate()
        {
            let gain = (n - 1 - i) as f32 / n as f32;
            frame.iter_mut().for_each(|x| *x *= gain);
        }
    }

    fn trim_silence(&mut self, threshold_db: f64) {
        let threshold = db_to_amplitude(threshold_db);
        let ch = self.channel_count();
        let loud = |frame: &[f32]| frame.iter().any(|x| x.abs() >= threshold);
        let mut frames = self.samples.chunks_exact(ch);
        let Some(start) = frames.position(loud) else {
            self.samples.clear();
            return;
        };
        let end = self.frames()
            - self
                .samples
                .chunks_exact(ch)
                .rev()
                .position(loud)
                .unwrap_or(0);
        self.keep_frames(start, end);
    }

    /// Converts to `target` channels: one is the average; from one, duplicates; otherwise
    /// channel `i` is source channel `i % n`.
    fn set_channels(&mut self, target: usize) {
        let ch = self.channel_count();
        if target == ch || target == 0 {
            return;
        }
        let frames = self.frames();
        let mut out = Vec::with_capacity(frames * target);
        for frame in self.samples.chunks_exact(ch) {
            if target == 1 {
                out.push(frame.iter().sum::<f32>() / ch as f32);
            } else {
                out.extend((0..target).map(|i| frame[i % ch]));
            }
        }
        self.samples = out;
        self.channels = target as u32;
    }

    fn make_stereo(&mut self) {
        match self.channel_count() {
            1 => self.set_channels(2),
            2 => {}
            ch => {
                let mut out = Vec::with_capacity(self.frames() * 2);
                for frame in self.samples.chunks_exact(ch) {
                    out.extend_from_slice(&frame[..2]);
                }
                self.samples = out;
                self.channels = 2;
            }
        }
    }

    fn resample(&mut self, rate: u32) -> Result<(), Code> {
        if rate == self.sample_rate {
            return Ok(());
        }
        let frames = self.frames();
        if frames > 0 {
            // The rate comes from the file header: refuse values that would make the
            // resampler's buffers explode.
            if !(MIN_SOURCE_SAMPLE_RATE..=MAX_SAMPLE_RATE).contains(&self.sample_rate) {
                return Err(Code::UnsupportedFormat);
            }
            let ch = self.channel_count();
            let out_frames = u128::from(rate) * frames as u128 / u128::from(self.sample_rate) + 1;
            check_len(usize::try_from(out_frames * ch as u128).unwrap_or(usize::MAX))?;
            let input =
                InterleavedSlice::new(&self.samples[..], ch, frames).map_err(|_| Code::Unknown)?;
            let mut resampler = Fft::<f32>::new(
                self.sample_rate as usize,
                rate as usize,
                1024,
                ch,
                FixedSync::Input,
            )
            .map_err(|_| Code::InvalidParameter)?;
            let output = resampler
                .process_all(&input, frames, None)
                .map_err(|_| Code::Unknown)?;
            self.samples = output.take_data();
        }
        self.sample_rate = rate;
        Ok(())
    }

    /// Brings `other` to this format: channels first, then the rate.
    fn conform(&self, mut other: Decoded) -> Result<Decoded, Code> {
        other.set_channels(self.channel_count());
        other.resample(self.sample_rate)?;
        Ok(other)
    }

    fn append(&mut self, other: Decoded, crossfade_us: u64) -> Result<(), Code> {
        let other = self.conform(other)?;
        let ch = self.channel_count();
        let n = us_to_frames(crossfade_us, self.sample_rate)
            .min(self.frames())
            .min(other.frames());
        check_len(
            self.samples
                .len()
                .saturating_add(other.samples.len() - n * ch),
        )?;
        let overlap_start = (self.frames() - n) * ch;
        for i in 0..n {
            let t = (i as f32 + 0.5) / n as f32 * std::f32::consts::FRAC_PI_2;
            let (fade_out, fade_in) = (t.cos(), t.sin());
            for c in 0..ch {
                let a = &mut self.samples[overlap_start + i * ch + c];
                *a = *a * fade_out + other.samples[i * ch + c] * fade_in;
            }
        }
        self.samples.extend_from_slice(&other.samples[n * ch..]);
        Ok(())
    }

    fn mix(&mut self, other: Decoded, gain_db: f64, offset_us: u64) -> Result<(), Code> {
        let other = self.conform(other)?;
        let ch = self.channel_count();
        let gain = db_to_amplitude(gain_db);
        let offset = us_to_frames(offset_us, self.sample_rate)
            .checked_mul(ch)
            .ok_or(Code::InvalidParameter)?;
        let end = offset
            .checked_add(other.samples.len())
            .ok_or(Code::InvalidParameter)?;
        check_len(end)?;
        if end > self.samples.len() {
            self.samples
                .try_reserve_exact(end - self.samples.len())
                .map_err(|_| Code::InvalidParameter)?;
            self.samples.resize(end, 0.0);
        }
        for (a, b) in self.samples[offset..end].iter_mut().zip(&other.samples) {
            *a += b * gain;
        }
        Ok(())
    }
}

/// Decodes `audio` and applies `ops`; `sources` are the extra sources `Append` and `Mix`
/// refer to, each decoded at most once.
pub fn render(
    audio: &FrustbiteAudio,
    sources: &[&FrustbiteAudio],
    ops: &[Op],
) -> Result<Decoded, Code> {
    let mut pcm = audio.decode()?;
    let mut decoded: Vec<Option<Decoded>> = vec![None; sources.len()];
    let mut take = |index: usize| -> Result<Decoded, Code> {
        if let Some(pcm) = &decoded[index] {
            return Ok(pcm.clone());
        }
        let pcm = sources[index].decode()?;
        decoded[index] = Some(pcm.clone());
        Ok(pcm)
    };
    for op in ops {
        match *op {
            Op::Trim { start_us, end_us } => pcm.trim(start_us, end_us),
            Op::Gain { db } => pcm.scale(db_to_amplitude(db)),
            Op::Normalize { peak_db } => pcm.normalize(peak_db),
            Op::FadeIn { duration_us } => pcm.fade_in(duration_us),
            Op::FadeOut { duration_us } => pcm.fade_out(duration_us),
            Op::Resample { sample_rate } => pcm.resample(sample_rate)?,
            Op::ToMono {} => pcm.set_channels(1),
            Op::ToStereo {} => pcm.make_stereo(),
            Op::TrimSilence { threshold_db } => pcm.trim_silence(threshold_db),
            Op::Append {
                source,
                crossfade_us,
            } => pcm.append(take(source)?, crossfade_us)?,
            Op::Mix {
                source,
                gain_db,
                offset_us,
            } => pcm.mix(take(source)?, gain_db, offset_us)?,
        }
    }
    Ok(pcm)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pcm(samples: Vec<f32>, sample_rate: u32, channels: u32) -> Decoded {
        Decoded {
            samples,
            sample_rate,
            channels,
        }
    }

    /// `frames` frames of a constant `value` in every channel.
    fn flat(value: f32, frames: usize, rate: u32, channels: u32) -> Decoded {
        pcm(vec![value; frames * channels as usize], rate, channels)
    }

    #[test]
    fn parses_every_op_and_rejects_bad_json() {
        let json = br#"[
            {"op":"trim","start_us":0,"end_us":null},
            {"op":"trim","start_us":5,"end_us":10},
            {"op":"gain","db":-3.5},
            {"op":"normalize","peak_db":-1},
            {"op":"fade_in","duration_us":100},
            {"op":"fade_out","duration_us":100},
            {"op":"resample","sample_rate":16000},
            {"op":"to_mono"},
            {"op":"to_stereo"},
            {"op":"trim_silence","threshold_db":-50},
            {"op":"append","source":0,"crossfade_us":0},
            {"op":"mix","source":0,"gain_db":-12,"offset_us":0}
        ]"#;
        assert_eq!(parse_ops(json, 1).unwrap().len(), 12);
        assert_eq!(parse_ops(b"", 0).unwrap(), Vec::new());
        assert_eq!(parse_ops(b"[]", 0).unwrap(), Vec::new());
        for bad in [
            &br#"[{"op":"reverse"}]"#[..],
            br#"[{"op":"gain"}]"#,
            br#"[{"op":"gain","db":1,"extra":2}]"#,
            br#"[{"op":"to_mono","x":1}]"#,
            br#"{"op":"to_mono"}"#,
            br#"[{"op":"trim","start_us":-1,"end_us":null}]"#,
            b"not json",
        ] {
            assert_eq!(
                parse_ops(bad, 1),
                Err(Code::InvalidParameter),
                "{}",
                String::from_utf8_lossy(bad)
            );
        }
    }

    #[test]
    fn validation_rejects_out_of_range_parameters() {
        for bad in [
            r#"[{"op":"trim","start_us":10,"end_us":5}]"#,
            r#"[{"op":"normalize","peak_db":0.5}]"#,
            r#"[{"op":"resample","sample_rate":0}]"#,
            r#"[{"op":"resample","sample_rate":768001}]"#,
            r#"[{"op":"trim_silence","threshold_db":1}]"#,
            r#"[{"op":"append","source":1,"crossfade_us":0}]"#,
            r#"[{"op":"mix","source":1,"gain_db":0,"offset_us":0}]"#,
        ] {
            assert_eq!(
                parse_ops(bad.as_bytes(), 1),
                Err(Code::InvalidParameter),
                "{bad}"
            );
        }
    }

    #[test]
    fn us_to_frames_rounds_and_saturates() {
        assert_eq!(us_to_frames(1_000_000, 44_100), 44_100);
        assert_eq!(us_to_frames(11, 44_100), 0);
        assert_eq!(us_to_frames(12, 44_100), 1);
        // No overflow on the largest inputs.
        assert!(us_to_frames(u64::MAX, MAX_SAMPLE_RATE) > 0);
    }

    #[test]
    fn trim_keeps_the_range_and_clamps() {
        let mut p = pcm((0..20).map(|i| i as f32).collect(), 10, 2);
        p.trim(200_000, Some(500_000));
        assert_eq!(p.samples, vec![4.0, 5.0, 6.0, 7.0, 8.0, 9.0]);
        let mut p = flat(1.0, 10, 10, 1);
        p.trim(5_000_000, None);
        assert!(p.samples.is_empty());
        let mut p = flat(1.0, 10, 10, 1);
        p.trim(0, Some(99_000_000));
        assert_eq!(p.frames(), 10);
    }

    #[test]
    fn gain_and_normalize() {
        let mut p = pcm(vec![0.5, -0.25], 10, 1);
        p.scale(db_to_amplitude(-6.020_599_913_279_624));
        assert!((p.samples[0] - 0.25).abs() < 1e-6);
        let mut p = pcm(vec![0.5, -0.25], 10, 1);
        p.normalize(0.0);
        assert_eq!(p.samples, vec![1.0, -0.5]);
        let mut p = pcm(vec![0.5, -0.25], 10, 1);
        p.normalize(-1.0);
        assert!((p.samples[0] - 0.891_250_9).abs() < 1e-6);
        let mut silence = flat(0.0, 4, 10, 1);
        silence.normalize(-1.0);
        assert_eq!(silence.samples, vec![0.0; 4]);
    }

    #[test]
    fn fades_are_linear_and_clamp_to_length() {
        let mut p = flat(1.0, 10, 10, 2);
        p.fade_in(400_000);
        assert_eq!(
            &p.samples[..8],
            &[0.0, 0.0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75]
        );
        assert_eq!(p.samples[8], 1.0);
        let mut p = flat(1.0, 10, 10, 1);
        p.fade_out(400_000);
        assert_eq!(&p.samples[6..], &[0.75, 0.5, 0.25, 0.0]);
        assert_eq!(p.samples[5], 1.0);
        let mut p = flat(1.0, 4, 10, 1);
        p.fade_out(99_000_000);
        assert_eq!(p.samples, vec![0.75, 0.5, 0.25, 0.0]);
        let mut empty = flat(1.0, 0, 10, 1);
        empty.fade_in(1_000);
        empty.fade_out(1_000);
        assert!(empty.samples.is_empty());
    }

    #[test]
    fn channel_conversions() {
        let mut p = pcm(vec![1.0, 0.0, 0.5, 0.5], 10, 2);
        p.set_channels(1);
        assert_eq!((p.samples.clone(), p.channels), (vec![0.5, 0.5], 1));
        p.make_stereo();
        assert_eq!(
            (p.samples.clone(), p.channels),
            (vec![0.5, 0.5, 0.5, 0.5], 2)
        );
        let mut six = pcm((0..12).map(|i| i as f32).collect(), 10, 6);
        six.make_stereo();
        assert_eq!(six.samples, vec![0.0, 1.0, 6.0, 7.0]);
        let mut stereo = pcm(vec![1.0, 2.0], 10, 2);
        stereo.set_channels(3);
        assert_eq!(stereo.samples, vec![1.0, 2.0, 1.0]);
    }

    #[test]
    fn trim_silence_drops_quiet_edges() {
        let mut p = pcm(
            vec![0.0, 0.0, 0.001, 0.0, 0.5, 0.0, 0.2, 0.0, 0.0001, 0.0],
            10,
            2,
        );
        p.trim_silence(-50.0);
        assert_eq!(p.samples, vec![0.5, 0.0, 0.2, 0.0]);
        let mut quiet = flat(0.0001, 8, 10, 1);
        quiet.trim_silence(-50.0);
        assert!(quiet.samples.is_empty());
        let mut empty = flat(0.0, 0, 10, 1);
        empty.trim_silence(-50.0);
        assert!(empty.samples.is_empty());
    }

    /// Amplitude of a sine at `freq` in a mono signal (Goertzel, normalized by length).
    fn tone_amplitude(signal: &[f32], rate: u32, freq: f64) -> f64 {
        let coeff = 2.0 * (2.0 * std::f64::consts::PI * freq / f64::from(rate)).cos();
        let (mut s1, mut s2) = (0.0f64, 0.0f64);
        for &x in signal {
            let s0 = f64::from(x) + coeff * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        (s1 * s1 + s2 * s2 - coeff * s1 * s2).sqrt() * 2.0 / signal.len() as f64
    }

    fn sine(freq: f64, rate: u32, frames: usize, amplitude: f32) -> Vec<f32> {
        (0..frames)
            .map(|i| {
                amplitude
                    * (2.0 * std::f64::consts::PI * freq * i as f64 / f64::from(rate)).sin() as f32
            })
            .collect()
    }

    #[test]
    fn resample_keeps_length_and_tone() {
        let mut p = pcm(sine(1000.0, 44_100, 44_100, 0.5), 44_100, 1);
        p.resample(16_000).unwrap();
        assert_eq!(p.sample_rate, 16_000);
        assert!(p.frames().abs_diff(16_000) <= 1, "{}", p.frames());
        let amplitude = tone_amplitude(&p.samples[1000..15_000], 16_000, 1000.0);
        assert!((amplitude - 0.5).abs() < 0.01, "{amplitude}");
        // A tone above the new Nyquist frequency is filtered out, not aliased.
        let mut high = pcm(sine(12_000.0, 44_100, 44_100, 0.5), 44_100, 1);
        high.resample(16_000).unwrap();
        let alias = tone_amplitude(&high.samples[1000..15_000], 16_000, 4000.0);
        assert!(alias < 0.001, "{alias}");
    }

    #[test]
    fn resample_is_a_no_op_at_the_same_rate_and_handles_empty() {
        let mut p = pcm(vec![0.1, 0.2], 8000, 1);
        p.resample(8000).unwrap();
        assert_eq!(p.samples, vec![0.1, 0.2]);
        let mut empty = flat(0.0, 0, 8000, 2);
        empty.resample(48_000).unwrap();
        assert_eq!((empty.frames(), empty.sample_rate), (0, 48_000));
    }

    #[test]
    fn resample_refuses_absurd_source_rates() {
        for rate in [1, 999, 3_000_000_019] {
            let mut p = flat(0.1, 10, rate, 1);
            assert_eq!(p.resample(44_100), Err(Code::UnsupportedFormat), "{rate}");
        }
        // Appending such a source converts it, so it is refused too.
        let mut a = flat(0.0, 10, 44_100, 1);
        assert_eq!(
            a.append(flat(0.1, 10, 1, 1), 0),
            Err(Code::UnsupportedFormat)
        );
        // An empty source only changes its rate.
        let mut empty = flat(0.0, 0, 1, 1);
        empty.resample(44_100).unwrap();
    }

    #[test]
    fn growth_past_the_wav_limit_fails_before_allocating() {
        let mut a = flat(0.0, 10, 48_000, 2);
        // A day at 48 kHz stereo: about 8.3e9 samples.
        let offset_us = 24 * 3600 * 1_000_000;
        assert_eq!(
            a.mix(flat(1.0, 10, 48_000, 2), 0.0, offset_us),
            Err(Code::InvalidParameter)
        );
        assert_eq!(a.samples.len(), 20);
        assert_eq!(check_len(MAX_SAMPLES), Ok(()));
        assert_eq!(check_len(MAX_SAMPLES + 1), Err(Code::InvalidParameter));
    }

    #[test]
    fn append_concatenates_and_conforms() {
        let mut a = flat(1.0, 4, 10, 2);
        a.append(flat(0.5, 3, 10, 1), 0).unwrap();
        assert_eq!(a.frames(), 7);
        assert_eq!(&a.samples[8..], &[0.5; 6]);
        let mut a = flat(0.0, 100, 8000, 1);
        a.append(flat(0.0, 160, 16_000, 1), 0).unwrap();
        assert!(a.frames().abs_diff(180) <= 1, "{}", a.frames());
    }

    #[test]
    fn crossfade_is_equal_power_and_shortens_by_the_overlap() {
        let mut a = flat(1.0, 10, 10, 1);
        a.append(flat(1.0, 10, 10, 1), 400_000).unwrap();
        assert_eq!(a.frames(), 16);
        // cos + sin of the same angle: rises above 1 in the middle (equal power, not gain).
        let middle = a.samples[7];
        assert!(middle > 1.3 && middle < 1.42, "{middle}");
        // Overlap clamps to the shorter side.
        let mut short = flat(1.0, 2, 10, 1);
        short.append(flat(1.0, 10, 10, 1), 9_000_000).unwrap();
        assert_eq!(short.frames(), 10);
    }

    #[test]
    fn mix_adds_with_gain_and_offset_and_extends() {
        let mut a = flat(0.5, 4, 10, 1);
        a.mix(flat(1.0, 3, 10, 1), -6.020_599_913_279_624, 200_000)
            .unwrap();
        assert_eq!(a.frames(), 5);
        assert_eq!(a.samples[0], 0.5);
        assert!((a.samples[2] - 1.0).abs() < 1e-6);
        assert!((a.samples[4] - 0.5).abs() < 1e-6);
    }

    #[cfg(feature = "wav")]
    #[test]
    fn render_runs_the_pipeline_in_order() {
        const FIXTURES: &str = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../packages/frustbite/test/fixtures/"
        );
        let audio = FrustbiteAudio::open_file(format!("{FIXTURES}tone.wav"), None).unwrap();
        let click = FrustbiteAudio::open_file(format!("{FIXTURES}click.wav"), None).unwrap();
        let ops = parse_ops(
            br#"[{"op":"trim","start_us":0,"end_us":1000000},
                 {"op":"to_mono"},
                 {"op":"resample","sample_rate":16000},
                 {"op":"append","source":0,"crossfade_us":0},
                 {"op":"append","source":0,"crossfade_us":0},
                 {"op":"normalize","peak_db":-3}]"#,
            1,
        )
        .unwrap();
        let out = render(&audio, &[&click], &ops).unwrap();
        assert_eq!((out.sample_rate, out.channels), (16_000, 1));
        let click_frames = {
            let mut c = click.decode().unwrap();
            c.set_channels(1);
            c.resample(16_000).unwrap();
            c.frames()
        };
        assert!(out.frames().abs_diff(16_000 + 2 * click_frames) <= 1);
        let peak = out.samples.iter().fold(0.0f32, |m, x| m.max(x.abs()));
        assert!((peak - db_to_amplitude(-3.0)).abs() < 1e-5, "{peak}");
    }
}
