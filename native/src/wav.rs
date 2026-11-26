//! WAV writing: interleaved f32 to a RIFF/WAVE byte buffer.

use crate::decode::Decoded;
use crate::error::FrustbiteErrorCode as Code;

/// Sample format of a written WAV. Values are part of the ABI.
///
/// cbindgen:prefix-with-name
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum FrustbiteWavFormat {
    /// 16-bit signed integer PCM.
    Pcm16 = 0,
    /// 24-bit signed integer PCM.
    Pcm24 = 1,
    /// 32-bit IEEE float, values outside [-1, 1] kept as they are.
    Float32 = 2,
}

impl FrustbiteWavFormat {
    /// Parses a caller-supplied value.
    pub fn from_u32(value: u32) -> Result<Self, Code> {
        match value {
            0 => Ok(Self::Pcm16),
            1 => Ok(Self::Pcm24),
            2 => Ok(Self::Float32),
            _ => Err(Code::InvalidParameter),
        }
    }

    fn bytes_per_sample(self) -> usize {
        match self {
            Self::Pcm16 => 2,
            Self::Pcm24 => 3,
            Self::Float32 => 4,
        }
    }
}

const WAVE_FORMAT_PCM: u16 = 1;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;

/// Scales `x` to a signed integer of `bits` bits: `round(x * 2^(bits-1))`, clamped. Readers
/// divide by `2^(bits-1)`, so an integer WAV read and written back at its depth is unchanged.
fn quantize(x: f32, bits: u32) -> i32 {
    let scale = f64::from(1u32 << (bits - 1));
    let value = (f64::from(x) * scale).round();
    // NaN becomes 0 through the saturating cast.
    value.clamp(-scale, scale - 1.0) as i32
}

/// Encodes `pcm` as a WAV file. Fails with `InvalidParameter` when the result cannot be
/// described by a RIFF header (over 4 GiB of data, or more than 65535 channels).
pub fn encode(pcm: &Decoded, format: FrustbiteWavFormat) -> Result<Vec<u8>, Code> {
    let channels = u16::try_from(pcm.channels).map_err(|_| Code::InvalidParameter)?;
    if channels == 0 {
        return Err(Code::InvalidParameter);
    }
    let bps = format.bytes_per_sample();
    let block_align =
        u16::try_from(usize::from(channels) * bps).map_err(|_| Code::InvalidParameter)?;
    let byte_rate = pcm
        .sample_rate
        .checked_mul(u32::from(block_align))
        .ok_or(Code::InvalidParameter)?;
    let frames = pcm.samples.len() / usize::from(channels);
    let samples = &pcm.samples[..frames * usize::from(channels)];
    let data_len = samples
        .len()
        .checked_mul(bps)
        .and_then(|len| u32::try_from(len).ok())
        .ok_or(Code::InvalidParameter)?;
    let pad = data_len % 2;
    let is_float = format == FrustbiteWavFormat::Float32;
    // fmt (16, or 18 with cbSize for a non-PCM tag), plus a `fact` chunk for float.
    let fmt_len: u32 = if is_float { 18 } else { 16 };
    let fact_len: u32 = if is_float { 12 } else { 0 };
    let riff_len = (4 + 8 + fmt_len + fact_len + 8)
        .checked_add(data_len)
        .and_then(|len| len.checked_add(pad))
        .ok_or(Code::InvalidParameter)?;

    let mut out = Vec::new();
    out.try_reserve_exact(riff_len as usize + 8)
        .map_err(|_| Code::InvalidParameter)?;
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&riff_len.to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&fmt_len.to_le_bytes());
    let tag = if is_float {
        WAVE_FORMAT_IEEE_FLOAT
    } else {
        WAVE_FORMAT_PCM
    };
    out.extend_from_slice(&tag.to_le_bytes());
    out.extend_from_slice(&channels.to_le_bytes());
    out.extend_from_slice(&pcm.sample_rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&((bps * 8) as u16).to_le_bytes());
    if is_float {
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(b"fact");
        out.extend_from_slice(&4u32.to_le_bytes());
        out.extend_from_slice(&u32::try_from(frames).unwrap_or(u32::MAX).to_le_bytes());
    }
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    match format {
        FrustbiteWavFormat::Pcm16 => {
            for &x in samples {
                out.extend_from_slice(&(quantize(x, 16) as i16).to_le_bytes());
            }
        }
        FrustbiteWavFormat::Pcm24 => {
            for &x in samples {
                out.extend_from_slice(&quantize(x, 24).to_le_bytes()[..3]);
            }
        }
        FrustbiteWavFormat::Float32 => {
            for &x in samples {
                out.extend_from_slice(&x.to_le_bytes());
            }
        }
    }
    if pad == 1 {
        out.push(0);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::probe::FrustbiteAudio;

    fn pcm(samples: Vec<f32>, sample_rate: u32, channels: u32) -> Decoded {
        Decoded {
            samples,
            sample_rate,
            channels,
        }
    }

    #[test]
    fn quantize_is_exact_for_integer_steps_and_clamps() {
        assert_eq!(quantize(0.0, 16), 0);
        assert_eq!(quantize(-1.0, 16), -32_768);
        assert_eq!(quantize(1.0, 16), 32_767);
        assert_eq!(quantize(2.5, 16), 32_767);
        assert_eq!(quantize(f32::NAN, 16), 0);
        assert_eq!(quantize(1234.0 / 32_768.0, 16), 1234);
        assert_eq!(quantize(-1.0, 24), -8_388_608);
    }

    #[test]
    fn header_fields_are_consistent() {
        let wav = encode(&pcm(vec![0.0; 6], 8000, 2), FrustbiteWavFormat::Pcm24).unwrap();
        // 6 samples * 3 bytes = 18 data bytes, even: no pad.
        assert_eq!(wav.len(), 44 + 18);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(wav[4..8].try_into().unwrap()), 36 + 18);
        assert_eq!(u16::from_le_bytes(wav[32..34].try_into().unwrap()), 6);
        assert_eq!(u32::from_le_bytes(wav[28..32].try_into().unwrap()), 48_000);
    }

    #[test]
    fn odd_data_is_padded() {
        let wav = encode(&pcm(vec![0.5], 8000, 1), FrustbiteWavFormat::Pcm24).unwrap();
        assert_eq!(wav.len(), 44 + 3 + 1);
        assert_eq!(u32::from_le_bytes(wav[40..44].try_into().unwrap()), 3);
    }

    #[test]
    fn rejects_unknown_format_and_zero_channels() {
        assert_eq!(FrustbiteWavFormat::from_u32(3), Err(Code::InvalidParameter));
        assert_eq!(
            encode(&pcm(vec![], 8000, 0), FrustbiteWavFormat::Pcm16),
            Err(Code::InvalidParameter)
        );
    }

    #[test]
    fn every_format_reads_back() {
        let samples: Vec<f32> = (0..2000).map(|i| (i as f32 * 0.01).sin() * 0.8).collect();
        let source = pcm(samples.clone(), 22_050, 2);
        for (format, tolerance) in [
            (FrustbiteWavFormat::Pcm16, 1.0 / 32_768.0),
            (FrustbiteWavFormat::Pcm24, 1.0 / 8_388_608.0),
            (FrustbiteWavFormat::Float32, 0.0),
        ] {
            let bytes = encode(&source, format).unwrap();
            let audio = FrustbiteAudio::open_memory(&bytes, None).unwrap();
            let info = audio.info().unwrap();
            assert_eq!((info.sample_rate, info.channels), (22_050, 2), "{format:?}");
            assert_eq!(info.total_frames, 1000, "{format:?}");
            let decoded = audio.decode().unwrap();
            assert_eq!(decoded.samples.len(), samples.len(), "{format:?}");
            let worst = decoded
                .samples
                .iter()
                .zip(&samples)
                .map(|(a, b)| (a - b).abs())
                .fold(0.0f32, f32::max);
            assert!(worst <= tolerance, "{format:?}: {worst}");
        }
    }

    #[test]
    fn pcm16_round_trip_is_lossless() {
        let bytes = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../packages/frustbite/test/fixtures/tone.wav"
        ))
        .unwrap();
        let decoded = FrustbiteAudio::open_memory(&bytes, None)
            .unwrap()
            .decode()
            .unwrap();
        let written = encode(&decoded, FrustbiteWavFormat::Pcm16).unwrap();
        let again = FrustbiteAudio::open_memory(&written, None)
            .unwrap()
            .decode()
            .unwrap();
        assert_eq!(again.samples, decoded.samples);
    }

    #[test]
    fn empty_float_wav_opens() {
        let bytes = encode(&pcm(vec![], 44_100, 1), FrustbiteWavFormat::Float32).unwrap();
        let audio = FrustbiteAudio::open_memory(&bytes, None).unwrap();
        assert_eq!(audio.info().unwrap().total_frames, 0);
        assert!(audio.decode().unwrap().samples.is_empty());
    }
}
