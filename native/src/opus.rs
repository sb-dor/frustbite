//! Opus decoding: `opus-pure` wrapped as a Symphonia `AudioDecoder`.
//!
//! Output is planar `f32` at 48 kHz. Pre-skip and end trimming are done by the caller
//! (see `native/RESEARCH.md`); the decoder only applies the `OpusHead` output gain.
//! Keep this module small: it is meant to be replaceable by `symphonia-opus`.

use std::sync::LazyLock;

use symphonia::core::audio::{
    AsGenericAudioBufferRef, AudioBuffer, AudioMut, AudioSpec, Channels, GenericAudioBufferRef,
    Position,
};
use symphonia::core::codecs::CodecInfo;
use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;
use symphonia::core::codecs::audio::{
    AudioCodecParameters, AudioDecoder, AudioDecoderOptions, FinalizeResult,
};
use symphonia::core::codecs::registry::{RegisterableAudioDecoder, SupportedAudioCodec};
use symphonia::core::errors::{Error, Result, unsupported_error};
use symphonia::core::packet::PacketRef;

/// Opus always decodes at 48 kHz here.
pub(crate) const OUTPUT_RATE: u32 = 48_000;
/// Longest packet: 120 ms at 48 kHz.
const MAX_PACKET_FRAMES: usize = 5760;
const OPUS_HEAD_MIN_LEN: usize = 19;

static CODEC_INFO: LazyLock<CodecInfo> = LazyLock::new(|| CodecInfo {
    short_name: "opus",
    long_name: "Opus Audio Codec",
    profiles: &[],
});

static SUPPORTED_CODECS: LazyLock<[SupportedAudioCodec; 1]> = LazyLock::new(|| {
    [SupportedAudioCodec {
        id: CODEC_ID_OPUS,
        info: *CODEC_INFO,
    }]
});

/// The fields of an `OpusHead` packet that matter for decoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpusHead {
    pub channels: u8,
    /// Frames (at 48 kHz) to drop from the start of the decoded output.
    pub pre_skip: u16,
    /// Output gain in Q7.8 dB.
    pub output_gain: i16,
}

impl OpusHead {
    /// Validates and parses an `OpusHead` packet (RFC 7845 section 5.1).
    ///
    /// Only mapping family 0 (mono or stereo) is supported in stage 1.
    pub fn parse(data: &[u8]) -> Result<Self> {
        if data.len() < OPUS_HEAD_MIN_LEN || &data[..8] != b"OpusHead" {
            return Err(Error::DecodeError("opus: invalid OpusHead"));
        }
        if data[8] >> 4 != 0 {
            return Err(Error::DecodeError("opus: unsupported OpusHead version"));
        }
        let channels = data[9];
        if channels == 0 {
            return Err(Error::DecodeError("opus: OpusHead has zero channels"));
        }
        if data[18] != 0 {
            return unsupported_error("opus: channel mapping family is not supported");
        }
        if channels > 2 {
            return Err(Error::DecodeError(
                "opus: family 0 allows only one or two channels",
            ));
        }
        Ok(Self {
            channels,
            pre_skip: u16::from_le_bytes([data[10], data[11]]),
            output_gain: i16::from_le_bytes([data[16], data[17]]),
        })
    }
}

/// Symphonia decoder for Opus streams with mapping family 0.
pub struct OpusDecoder {
    params: AudioCodecParameters,
    inner: opus_pure::OpusDecoder,
    channels: usize,
    buffer: AudioBuffer<f32>,
    interleaved: Vec<f32>,
}

impl OpusDecoder {
    fn try_new(params: &AudioCodecParameters, _options: &AudioDecoderOptions) -> Result<Self> {
        if params.codec != CODEC_ID_OPUS {
            return unsupported_error("opus: invalid codec");
        }
        // Never guess the layout: it must come from a valid OpusHead.
        let Some(extra) = params.extra_data.as_deref() else {
            return Err(Error::DecodeError("opus: missing OpusHead"));
        };
        let head = OpusHead::parse(extra)?;
        let channels = usize::from(head.channels);

        let mut inner = opus_pure::OpusDecoder::new(OUTPUT_RATE as i32, channels)
            .map_err(|_| Error::DecodeError("opus: cannot create decoder"))?;
        inner.gain_q8 = i32::from(head.output_gain);

        let layout = if channels == 1 {
            Channels::Positioned(Position::FRONT_CENTER)
        } else {
            Channels::Positioned(Position::FRONT_LEFT | Position::FRONT_RIGHT)
        };
        let mut params = params.clone();
        params
            .with_sample_rate(OUTPUT_RATE)
            .with_channels(layout.clone());

        Ok(Self {
            params,
            inner,
            channels,
            buffer: AudioBuffer::new(AudioSpec::new(OUTPUT_RATE, layout), MAX_PACKET_FRAMES),
            interleaved: vec![0.0; MAX_PACKET_FRAMES * channels],
        })
    }
}

impl AudioDecoder for OpusDecoder {
    fn reset(&mut self) {
        // The state of a freshly built decoder is always valid; failure only clears the buffer.
        let _ = self.inner.reset_state();
        self.buffer.clear();
    }

    fn codec_info(&self) -> &CodecInfo {
        &CODEC_INFO
    }

    fn codec_params(&self) -> &AudioCodecParameters {
        &self.params
    }

    fn decode_ref(&mut self, packet: &PacketRef<'_>) -> Result<GenericAudioBufferRef<'_>> {
        self.buffer.clear();
        // An empty packet is a lost packet: the decoder conceals it.
        let frames = self
            .inner
            .decode(packet.data, MAX_PACKET_FRAMES, &mut self.interleaved)
            .map_err(|_| Error::DecodeError("opus: corrupt packet"))?;

        self.buffer.render_uninit(Some(frames));
        for channel in 0..self.channels {
            let Some(plane) = self.buffer.plane_mut(channel) else {
                self.buffer.clear();
                return Err(Error::DecodeError("opus: missing output plane"));
            };
            for (frame, sample) in plane[..frames].iter_mut().enumerate() {
                *sample = self.interleaved[frame * self.channels + channel];
            }
        }
        Ok(self.buffer.as_generic_audio_buffer_ref())
    }

    fn finalize(&mut self) -> FinalizeResult {
        FinalizeResult::default()
    }

    fn last_decoded(&self) -> GenericAudioBufferRef<'_> {
        self.buffer.as_generic_audio_buffer_ref()
    }
}

impl RegisterableAudioDecoder for OpusDecoder {
    fn try_registry_new(
        params: &AudioCodecParameters,
        options: &AudioDecoderOptions,
    ) -> Result<Box<dyn AudioDecoder>> {
        Ok(Box::new(Self::try_new(params, options)?))
    }

    fn supported_codecs() -> &'static [SupportedAudioCodec] {
        &SUPPORTED_CODECS[..]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn head(version: u8, channels: u8, family: u8) -> Vec<u8> {
        let mut data = b"OpusHead".to_vec();
        data.extend([
            version, channels, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0x00, 0x01, family,
        ]);
        data
    }

    #[test]
    fn parses_pre_skip_and_gain() {
        let parsed = OpusHead::parse(&head(1, 2, 0)).unwrap();
        assert_eq!(parsed.channels, 2);
        assert_eq!(parsed.pre_skip, 312);
        assert_eq!(parsed.output_gain, 256);
    }

    #[test]
    fn rejects_invalid_heads() {
        assert!(OpusHead::parse(&[]).is_err());
        assert!(OpusHead::parse(&head(1, 0, 0)).is_err());
        assert!(OpusHead::parse(&head(0x10, 2, 0)).is_err());
        assert!(OpusHead::parse(&head(1, 3, 0)).is_err());
        let mut bad_magic = head(1, 2, 0);
        bad_magic[0] = b'X';
        assert!(OpusHead::parse(&bad_magic).is_err());
        assert!(matches!(
            OpusHead::parse(&head(1, 6, 1)),
            Err(Error::Unsupported(_))
        ));
    }

    #[test]
    fn decodes_first_packet_of_tone_opus() {
        use symphonia::core::codecs::audio::AudioDecoderOptions;
        use symphonia::core::formats::TrackType;

        let source = crate::source::AudioSource::File(
            concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../packages/frustbite/test/fixtures/tone.opus"
            )
            .into(),
        );
        let mut reader = symphonia::default::get_probe()
            .probe(
                &source.hint(None),
                source.open_stream().unwrap(),
                Default::default(),
                Default::default(),
            )
            .unwrap();
        let params = reader
            .first_track(TrackType::Audio)
            .and_then(|track| track.codec_params.as_ref())
            .and_then(|params| params.audio())
            .unwrap()
            .clone();
        let mut decoder = crate::codecs::registry()
            .make_audio_decoder(&params, &AudioDecoderOptions::default())
            .unwrap();
        let packet = reader.next_packet().unwrap().unwrap();
        let buffer = decoder.decode(&packet).unwrap();
        assert_eq!(buffer.frames(), 960);
        assert_eq!(buffer.spec().rate(), OUTPUT_RATE);
        assert_eq!(buffer.spec().channels().count(), 2);
    }
}
