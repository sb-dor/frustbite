//! Probing: container and codec detection, stream parameters and duration.

use std::sync::{Arc, OnceLock};

use symphonia::core::codecs::audio::well_known::profiles::{
    CODEC_PROFILE_AAC_HE, CODEC_PROFILE_AAC_HE_V2,
};
use symphonia::core::codecs::audio::well_known::{
    CODEC_ID_AAC, CODEC_ID_ALAC, CODEC_ID_FLAC, CODEC_ID_MP3, CODEC_ID_OPUS, CODEC_ID_PCM_ALAW,
    CODEC_ID_PCM_F32LE, CODEC_ID_PCM_F64LE, CODEC_ID_PCM_MULAW, CODEC_ID_PCM_S16LE,
    CODEC_ID_PCM_S24LE, CODEC_ID_PCM_S32LE, CODEC_ID_PCM_U8, CODEC_ID_VORBIS,
};
use symphonia::core::codecs::audio::{AudioCodecId, AudioCodecParameters, AudioDecoderOptions};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::well_known::{
    FORMAT_ID_ADTS, FORMAT_ID_FLAC, FORMAT_ID_ISOMP4, FORMAT_ID_MKV, FORMAT_ID_MP3, FORMAT_ID_OGG,
    FORMAT_ID_WAVE,
};
use symphonia::core::formats::{FormatId, FormatOptions, FormatReader, Track, TrackType};
use symphonia::core::meta::MetadataOptions;

use crate::codecs;
use crate::error::FrustbiteErrorCode as Code;
use crate::source::AudioSource;

/// Pass as `format` to detect the container from the content.
pub const FRUSTBITE_FORMAT_DETECT: u32 = u32::MAX;

/// Container formats. Values are part of the ABI.
///
/// cbindgen:prefix-with-name
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum FrustbiteContainer {
    /// MPEG audio stream.
    Mp3 = 0,
    /// ISO MP4 / M4A.
    Mp4 = 1,
    /// Native FLAC.
    Flac = 2,
    /// Ogg.
    Ogg = 3,
    /// RIFF WAVE.
    Wav = 4,
    /// Matroska / WebM.
    Mkv = 5,
    /// Raw AAC in ADTS frames.
    Adts = 6,
}

impl FrustbiteContainer {
    /// Parses a caller-supplied value; `FRUSTBITE_FORMAT_DETECT` means no hint.
    pub fn from_hint(value: u32) -> Result<Option<Self>, Code> {
        Ok(Some(match value {
            FRUSTBITE_FORMAT_DETECT => return Ok(None),
            0 => Self::Mp3,
            1 => Self::Mp4,
            2 => Self::Flac,
            3 => Self::Ogg,
            4 => Self::Wav,
            5 => Self::Mkv,
            6 => Self::Adts,
            _ => return Err(Code::InvalidParameter),
        }))
    }

    /// File extension used as a probe hint.
    pub fn extension(self) -> &'static str {
        match self {
            Self::Mp3 => "mp3",
            Self::Mp4 => "m4a",
            Self::Flac => "flac",
            Self::Ogg => "ogg",
            Self::Wav => "wav",
            Self::Mkv => "mkv",
            Self::Adts => "aac",
        }
    }

    fn from_format(id: FormatId) -> Option<Self> {
        Some(match id {
            FORMAT_ID_MP3 => Self::Mp3,
            FORMAT_ID_ISOMP4 => Self::Mp4,
            FORMAT_ID_FLAC => Self::Flac,
            FORMAT_ID_OGG => Self::Ogg,
            FORMAT_ID_WAVE => Self::Wav,
            FORMAT_ID_MKV => Self::Mkv,
            FORMAT_ID_ADTS => Self::Adts,
            _ => return None,
        })
    }
}

/// Audio codecs. Values are part of the ABI.
///
/// cbindgen:prefix-with-name
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum FrustbiteCodec {
    /// MPEG-1/2 Layer III.
    Mp3 = 0,
    /// AAC-LC.
    Aac = 1,
    /// Apple Lossless.
    Alac = 2,
    /// FLAC.
    Flac = 3,
    /// Vorbis.
    Vorbis = 4,
    /// Opus.
    Opus = 5,
    /// Uncompressed PCM.
    Pcm = 6,
}

impl FrustbiteCodec {
    fn from_id(id: AudioCodecId) -> Option<Self> {
        Some(match id {
            CODEC_ID_MP3 => Self::Mp3,
            CODEC_ID_AAC => Self::Aac,
            CODEC_ID_ALAC => Self::Alac,
            CODEC_ID_FLAC => Self::Flac,
            CODEC_ID_VORBIS => Self::Vorbis,
            CODEC_ID_OPUS => Self::Opus,
            CODEC_ID_PCM_U8 | CODEC_ID_PCM_S16LE | CODEC_ID_PCM_S24LE | CODEC_ID_PCM_S32LE
            | CODEC_ID_PCM_F32LE | CODEC_ID_PCM_F64LE | CODEC_ID_PCM_ALAW | CODEC_ID_PCM_MULAW => {
                Self::Pcm
            }
            _ => return None,
        })
    }
}

/// Description of an opened audio source.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(C)]
pub struct FrustbiteAudioInfo {
    /// A `FrustbiteContainer` value.
    pub container: u32,
    /// A `FrustbiteCodec` value.
    pub codec: u32,
    /// Sample rate in Hz (Opus is always 48000).
    pub sample_rate: u32,
    /// Channel count.
    pub channels: u32,
    /// Bits per sample for PCM, FLAC and ALAC; 0 when not applicable.
    pub bits_per_sample: u32,
    /// Average bitrate in bits per second; 0 when unknown.
    pub bitrate: u32,
    /// Frames per channel, with encoder delay and padding trimmed as far as the container
    /// allows:
    /// - exact: WAV, FLAC, MP3 with a LAME/Xing header, Vorbis, Ogg Opus and ALAC;
    /// - includes the 1024-frame encoder priming: AAC in MP4 (m4a, from the mdhd duration
    ///   without the edit list) and ADTS; decoding yields priming plus padding, so it is not
    ///   exactly the number of playable frames;
    /// - WebM Opus can carry up to one packet of tail padding;
    /// - MP3 without a LAME/Xing header is counted from the packets.
    pub total_frames: u64,
    /// Duration in microseconds.
    pub duration_us: u64,
}

/// What `open` learns without reading the whole stream.
pub(crate) struct Probed {
    container: FrustbiteContainer,
    codec: FrustbiteCodec,
    pub(crate) sample_rate: u32,
    pub(crate) channels: u32,
    bits_per_sample: u32,
    pub(crate) track_id: u32,
    /// Frames to drop from the start of decoded output (Opus pre-skip).
    pub(crate) pre_skip: u64,
    /// Frame count from the container, if it states one.
    pub(crate) known_frames: Option<u64>,
    /// MP3 only: the packet trims come from a LAME tag and can be trusted. Without one,
    /// Symphonia derives them from a bitrate-based length estimate that is wrong for VBR.
    pub(crate) mp3_trims_trusted: bool,
}

/// Consecutive undecodable packets after which a duration scan or a decode gives up.
pub(crate) const MAX_CONSECUTIVE_DECODE_ERRORS: u32 = 64;

/// An opened audio source. Immutable, so it can be shared between threads.
pub struct FrustbiteAudio {
    source: AudioSource,
    /// The caller's container hint; every re-open of the stream uses it.
    hint: Option<FrustbiteContainer>,
    probed: Probed,
    /// Size of the data, read once at open (for the bitrate estimate).
    data_size: u64,
    /// Only successful results are cached, so a transient failure can be retried.
    info: OnceLock<FrustbiteAudioInfo>,
    /// Tags and cover, read together on first use; only `Ok` is cached.
    tags: OnceLock<crate::tags::TagData>,
    #[cfg(test)]
    info_builds: std::sync::atomic::AtomicUsize,
    #[cfg(test)]
    pub(crate) tags_builds: std::sync::atomic::AtomicUsize,
}

// The Dart side shares one handle between isolates (decode on a background isolate), so a
// non-thread-safe field must fail the build here instead of becoming a data race.
const _: () = {
    const fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<FrustbiteAudio>();
};

impl FrustbiteAudio {
    /// Copies `data` and probes it.
    pub fn open_memory(data: &[u8], container: Option<FrustbiteContainer>) -> Result<Self, Code> {
        Self::open(AudioSource::Memory(Arc::from(data)), container)
    }

    /// Probes the file at `path`.
    pub fn open_file(
        path: impl Into<std::path::PathBuf>,
        container: Option<FrustbiteContainer>,
    ) -> Result<Self, Code> {
        Self::open(AudioSource::File(path.into()), container)
    }

    fn open(source: AudioSource, hint: Option<FrustbiteContainer>) -> Result<Self, Code> {
        let probed = probe(&source, hint)?;
        let data_size = source.data_size();
        Ok(Self {
            source,
            hint,
            probed,
            data_size,
            info: OnceLock::new(),
            tags: OnceLock::new(),
            #[cfg(test)]
            info_builds: std::sync::atomic::AtomicUsize::new(0),
            #[cfg(test)]
            tags_builds: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    /// Bytes this handle keeps in memory: the copied data for memory sources, 0 for files.
    pub fn byte_length(&self) -> usize {
        self.source.resident_bytes()
    }

    pub(crate) fn source(&self) -> &AudioSource {
        &self.source
    }

    pub(crate) fn hint(&self) -> Option<FrustbiteContainer> {
        self.hint
    }

    pub(crate) fn tags_cache(&self) -> &OnceLock<crate::tags::TagData> {
        &self.tags
    }

    pub(crate) fn probed(&self) -> &Probed {
        &self.probed
    }

    pub(crate) fn is_mp3(&self) -> bool {
        self.probed.codec == FrustbiteCodec::Mp3
    }

    pub(crate) fn is_opus(&self) -> bool {
        self.probed.codec == FrustbiteCodec::Opus
    }

    /// The stream description; computed on the first successful call and cached.
    pub fn info(&self) -> Result<FrustbiteAudioInfo, Code> {
        if let Some(info) = self.info.get() {
            return Ok(*info);
        }
        #[cfg(test)]
        self.info_builds
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let info = build_info(&self.source, self.hint, &self.probed, self.data_size)?;
        Ok(*self.info.get_or_init(|| info))
    }
}

pub(crate) fn map_error(error: &SymphoniaError) -> Code {
    match error {
        SymphoniaError::Unsupported(_) | SymphoniaError::LimitError(_) => Code::UnsupportedFormat,
        SymphoniaError::IoError(io) if io.kind() != std::io::ErrorKind::UnexpectedEof => {
            Code::IoError
        }
        _ => Code::DecodingError,
    }
}

pub(crate) fn open_reader(
    source: &AudioSource,
    container: Option<FrustbiteContainer>,
) -> Result<Box<dyn FormatReader + 'static>, Code> {
    let stream = source.open_stream()?;
    symphonia::default::get_probe()
        .probe(
            &source.hint(container),
            stream,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(|error| map_error(&error))
}

fn audio_params(track: &Track) -> Option<&AudioCodecParameters> {
    track.codec_params.as_ref()?.audio()
}

fn probe(source: &AudioSource, hint: Option<FrustbiteContainer>) -> Result<Probed, Code> {
    let reader = open_reader(source, hint)?;
    let container = FrustbiteContainer::from_format(reader.format_info().format)
        .ok_or(Code::UnsupportedFormat)?;
    let track = reader
        .default_track(TrackType::Audio)
        .or_else(|| reader.first_track(TrackType::Audio))
        .ok_or(Code::UnsupportedFormat)?;
    let params = audio_params(track).ok_or(Code::UnsupportedFormat)?;
    let codec = FrustbiteCodec::from_id(params.codec).ok_or(Code::UnsupportedFormat)?;

    // Opus in MP4 is not supported: the dOps header is mis-parsed upstream.
    if container == FrustbiteContainer::Mp4 && codec == FrustbiteCodec::Opus {
        return Err(Code::UnsupportedFormat);
    }
    // The AAC decoder handles AAC-LC only; refuse SBR streams up front.
    if codec == FrustbiteCodec::Aac
        && (matches!(
            params.profile,
            Some(CODEC_PROFILE_AAC_HE | CODEC_PROFILE_AAC_HE_V2)
        ) || params
            .extra_data
            .as_deref()
            .is_some_and(codecs::aac_uses_sbr))
    {
        return Err(Code::UnsupportedFormat);
    }
    // Building the decoder validates the parameters (OpusHead, AAC object type, ...).
    codecs::registry()
        .make_audio_decoder(params, &AudioDecoderOptions::default())
        .map_err(|error| map_error(&error))?;

    let (sample_rate, pre_skip, known_frames, opus_channels) = if codec == FrustbiteCodec::Opus {
        let stream = opus_stream(params)?;
        (
            stream.sample_rate,
            stream.pre_skip,
            None,
            Some(stream.channels),
        )
    } else {
        (
            params.sample_rate.ok_or(Code::DecodingError)?,
            0,
            // MPEG audio without a Xing/Info/VBRI header only gets a bitrate-based estimate
            // from Symphonia, which is wrong for VBR: always count its packets instead.
            if codec == FrustbiteCodec::Mp3 {
                None
            } else {
                track.num_frames
            },
            None,
        )
    };
    let channels = match opus_channels {
        Some(channels) => channels,
        None => params
            .channels
            .as_ref()
            .map(|channels| channels.count())
            .and_then(|count| u32::try_from(count).ok())
            .filter(|&count| count > 0)
            .ok_or(Code::DecodingError)?,
    };
    let bits_per_sample = match codec {
        FrustbiteCodec::Pcm | FrustbiteCodec::Flac | FrustbiteCodec::Alac => params
            .bits_per_sample
            .or(params.bits_per_coded_sample)
            .unwrap_or(0),
        _ => 0,
    };
    let bits_per_sample = match (codec, bits_per_sample) {
        (FrustbiteCodec::Alac, 0) => params
            .extra_data
            .as_deref()
            .and_then(codecs::alac_bit_depth)
            .unwrap_or(0),
        (_, bits) => bits,
    };

    Ok(Probed {
        container,
        codec,
        sample_rate,
        channels,
        bits_per_sample,
        track_id: track.id,
        pre_skip,
        known_frames,
        mp3_trims_trusted: codec == FrustbiteCodec::Mp3 && track.delay.is_some(),
    })
}

/// What an Opus stream's OpusHead dictates. The rate is always 48 kHz, and the pre-skip and
/// channel count come from the OpusHead, never from `Track::delay` or the container's channels
/// (Matroska defaults a missing channel count to 1).
struct OpusStream {
    sample_rate: u32,
    pre_skip: u64,
    channels: u32,
}

#[cfg(feature = "opus")]
fn opus_stream(params: &AudioCodecParameters) -> Result<OpusStream, Code> {
    let extra = params.extra_data.as_deref().ok_or(Code::DecodingError)?;
    let head = crate::opus::OpusHead::parse(extra).map_err(|error| map_error(&error))?;
    Ok(OpusStream {
        sample_rate: crate::opus::OUTPUT_RATE,
        pre_skip: u64::from(head.pre_skip),
        channels: u32::from(head.channels),
    })
}

#[cfg(not(feature = "opus"))]
fn opus_stream(_params: &AudioCodecParameters) -> Result<OpusStream, Code> {
    Err(Code::UnsupportedFormat)
}

fn build_info(
    source: &AudioSource,
    hint: Option<FrustbiteContainer>,
    probed: &Probed,
    data_size: u64,
) -> Result<FrustbiteAudioInfo, Code> {
    let total_frames = match probed.known_frames {
        Some(frames) => frames,
        None => scan_frames(source, hint, probed)?,
    };
    let rate = u64::from(probed.sample_rate);
    let duration_us = total_frames.saturating_mul(1_000_000) / rate.max(1);
    let bitrate = if probed.codec == FrustbiteCodec::Pcm && probed.bits_per_sample > 0 {
        u64::from(probed.sample_rate)
            * u64::from(probed.channels)
            * u64::from(probed.bits_per_sample)
    } else {
        data_size
            .saturating_mul(8_000_000)
            .checked_div(duration_us)
            .unwrap_or(0)
    };
    Ok(FrustbiteAudioInfo {
        container: probed.container as u32,
        codec: probed.codec as u32,
        sample_rate: probed.sample_rate,
        channels: probed.channels,
        bits_per_sample: probed.bits_per_sample,
        bitrate: u32::try_from(bitrate).unwrap_or(u32::MAX),
        total_frames,
        duration_us,
    })
}

/// Sums packet durations to the end of the stream without decoding.
fn scan_frames(
    source: &AudioSource,
    hint: Option<FrustbiteContainer>,
    probed: &Probed,
) -> Result<u64, Code> {
    let mut reader = open_reader(source, hint)?;
    let time_base = reader
        .tracks()
        .iter()
        .find(|track| track.id == probed.track_id)
        .ok_or(Code::DecodingError)?
        .time_base;

    let mut units: u128 = 0;
    let mut consecutive_errors = 0u32;
    loop {
        match reader.next_packet() {
            Ok(Some(packet)) => {
                consecutive_errors = 0;
                if packet.track_id == probed.track_id {
                    let mut dur = u128::from(packet.dur.get());
                    // WORKAROUND for an upstream bug: symphonia-core 0.6.1 src/packet.rs:340
                    // (`PacketBuilder::trimmed_dur`) subtracts the builder's zeroed trim fields
                    // instead of the computed trims, so the MP3 demuxer leaves the trims inside
                    // `dur`. We subtract them here. The symphonia crates are pinned to `=0.6.1`
                    // in Cargo.toml so a fix upstream cannot make this subtract twice.
                    if probed.mp3_trims_trusted {
                        let trim = packet
                            .trim_start
                            .get()
                            .saturating_add(packet.trim_end.get());
                        dur = dur.saturating_sub(u128::from(trim));
                    }
                    units += dur;
                }
            }
            Ok(None) => break,
            // A truncated file ends the scan early; keep what was counted.
            Err(SymphoniaError::IoError(io)) if io.kind() == std::io::ErrorKind::UnexpectedEof => {
                break;
            }
            Err(SymphoniaError::DecodeError(_)) if units > 0 => {
                consecutive_errors += 1;
                if consecutive_errors >= MAX_CONSECUTIVE_DECODE_ERRORS {
                    break;
                }
            }
            Err(error) => return Err(map_error(&error)),
        }
    }

    let frames = match time_base {
        Some(base) => {
            let rate = u128::from(probed.sample_rate);
            let denom = u128::from(base.denom.get());
            (units * u128::from(base.numer.get()) * rate + denom / 2) / denom
        }
        None => units,
    };
    let frames = u64::try_from(frames).map_err(|_| Code::DecodingError)?;
    Ok(frames.saturating_sub(probed.pre_skip))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../packages/frustbite/test/fixtures/"
    );

    fn open(name: &str) -> Result<FrustbiteAudio, Code> {
        FrustbiteAudio::open_file(format!("{FIXTURES}{name}"), None)
    }

    #[cfg(any(
        feature = "wav",
        all(
            feature = "mp3",
            feature = "aac",
            feature = "alac",
            feature = "flac",
            feature = "vorbis",
            feature = "opus"
        )
    ))]
    fn info(name: &str) -> FrustbiteAudioInfo {
        open(name).unwrap().info().unwrap()
    }

    #[cfg(feature = "wav")]
    #[test]
    fn info_wav() {
        let info = info("tone.wav");
        assert_eq!(info.codec, FrustbiteCodec::Pcm as u32);
        assert_eq!(info.container, FrustbiteContainer::Wav as u32);
        assert_eq!(info.sample_rate, 44_100);
        assert_eq!(info.channels, 2);
        assert_eq!(info.bits_per_sample, 16);
        assert_eq!(info.total_frames, 132_300);
        assert_eq!(info.duration_us, 3_000_000);
        assert_eq!(info.bitrate, 1_411_200);
    }

    #[test]
    fn open_corrupt_is_unsupported_or_decoding_error() {
        let code = open("corrupt.bin").err().unwrap();
        assert!(matches!(
            code,
            Code::UnsupportedFormat | Code::DecodingError
        ));
    }

    #[test]
    fn open_empty_is_an_error() {
        let code = FrustbiteAudio::open_memory(&[], None).err().unwrap();
        assert!(matches!(
            code,
            Code::UnsupportedFormat | Code::DecodingError
        ));
    }

    #[test]
    fn open_missing_file_is_invalid_path() {
        assert_eq!(open("does_not_exist.wav").err(), Some(Code::InvalidPath));
    }

    #[test]
    fn container_hint_is_validated() {
        assert_eq!(
            FrustbiteContainer::from_hint(FRUSTBITE_FORMAT_DETECT),
            Ok(None)
        );
        assert_eq!(
            FrustbiteContainer::from_hint(4),
            Ok(Some(FrustbiteContainer::Wav))
        );
        assert_eq!(
            FrustbiteContainer::from_hint(7),
            Err(Code::InvalidParameter)
        );
    }

    /// Tests that need every codec compiled in.
    #[cfg(all(
        feature = "mp3",
        feature = "aac",
        feature = "alac",
        feature = "flac",
        feature = "vorbis",
        feature = "opus"
    ))]
    mod all_codecs {
        use super::*;

        #[test]
        fn info_each_supported_fixture() {
            use FrustbiteCodec as Co;
            use FrustbiteContainer as Ct;
            let table = [
                ("tone.wav", Ct::Wav, Co::Pcm),
                ("tone.mp3", Ct::Mp3, Co::Mp3),
                ("tone_vbr_noxing.mp3", Ct::Mp3, Co::Mp3),
                ("tone.m4a", Ct::Mp4, Co::Aac),
                ("tone.aac", Ct::Adts, Co::Aac),
                ("tone_alac.m4a", Ct::Mp4, Co::Alac),
                ("tone.flac", Ct::Flac, Co::Flac),
                ("tone.ogg", Ct::Ogg, Co::Vorbis),
                ("tone.opus", Ct::Ogg, Co::Opus),
                ("tone.webm", Ct::Mkv, Co::Opus),
            ];
            for (name, container, codec) in table {
                let info = info(name);
                assert_eq!(info.container, container as u32, "{name} container");
                assert_eq!(info.codec, codec as u32, "{name} codec");
                assert_eq!(info.channels, 2, "{name} channels");
                assert!(
                    info.duration_us.abs_diff(3_000_000) < 50_000,
                    "{name} duration {}",
                    info.duration_us
                );
                assert!(info.bitrate > 0, "{name} bitrate");
            }
        }

        #[test]
        fn info_adts_is_aac_lc_44k() {
            let info = info("tone.aac");
            assert_eq!(info.container, FrustbiteContainer::Adts as u32);
            assert_eq!(info.codec, FrustbiteCodec::Aac as u32);
            assert_eq!((info.sample_rate, info.channels), (44_100, 2));
            assert!(info.duration_us.abs_diff(3_000_000) < 50_000);
        }

        #[test]
        fn info_reports_bit_depth_of_lossless_codecs() {
            assert_eq!(info("tone_alac.m4a").bits_per_sample, 24);
            assert_eq!(info("tone.flac").bits_per_sample, 24);
            assert_eq!(info("silence.flac").bits_per_sample, 16);
            assert_eq!(info("tone.ogg").bits_per_sample, 0);
        }

        #[test]
        fn info_short_and_silent_fixtures() {
            let click = info("click.wav");
            assert_eq!((click.channels, click.total_frames), (1, 2205));
            assert_eq!(click.duration_us, 50_000);
            assert_eq!(info("silence.flac").duration_us, 1_000_000);
        }

        #[test]
        fn info_mp3_frames_are_exact() {
            assert_eq!(info("tone.mp3").total_frames, 132_300);
        }

        #[test]
        fn info_opus_is_48k() {
            assert_eq!(info("tone.opus").sample_rate, 48_000);
            assert_eq!(info("tone.webm").sample_rate, 48_000);
        }

        #[test]
        fn info_opus_frames_exclude_pre_skip() {
            assert_eq!(info("tone.opus").total_frames, 144_000);
        }

        #[test]
        fn info_scans_duration_when_header_missing() {
            for name in ["tone.webm", "tone_vbr_noxing.mp3"] {
                let us = info(name).duration_us;
                assert!(us.abs_diff(3_000_000) < 50_000, "{name}: {us}");
            }
        }

        #[test]
        fn info_is_cached() {
            use std::sync::atomic::Ordering;
            let audio = open("tone_vbr_noxing.mp3").unwrap();
            let first = audio.info().unwrap();
            assert_eq!(audio.info().unwrap(), first);
            assert_eq!(audio.info_builds.load(Ordering::SeqCst), 1);
        }

        #[test]
        fn open_he_aac_is_unsupported() {
            assert_eq!(open("tone_he.m4a").err(), Some(Code::UnsupportedFormat));
        }

        #[test]
        fn open_truncated_mp3_succeeds() {
            let audio = open("truncated.mp3").unwrap();
            assert!(audio.info().unwrap().total_frames > 0);
        }

        #[test]
        fn open_tagged_and_untagged_fixtures() {
            assert!(open("id3v1_cp1251.mp3").is_ok());
            assert!(open("notags.wav").is_ok());
        }

        #[test]
        fn open_memory_matches_open_file() {
            let bytes = std::fs::read(format!("{FIXTURES}tone.flac")).unwrap();
            let from_memory = FrustbiteAudio::open_memory(&bytes, None).unwrap();
            assert_eq!(from_memory.info(), open("tone.flac").unwrap().info());
            assert_eq!(from_memory.byte_length(), bytes.len());
        }
    }

    #[cfg(feature = "opus")]
    #[test]
    fn opus_channels_come_from_opus_head_not_container() {
        use symphonia::core::audio::{Channels, Position};
        use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;

        let mut head = b"OpusHead".to_vec();
        head.extend([1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]);
        let mut params = AudioCodecParameters::new();
        params
            .for_codec(CODEC_ID_OPUS)
            // The container claims mono, as Matroska does when the element is missing.
            .with_channels(Channels::Positioned(Position::FRONT_CENTER))
            .with_extra_data(head.into_boxed_slice());
        let stream = opus_stream(&params).unwrap();
        assert_eq!(stream.channels, 2);
        assert_eq!(stream.pre_skip, 312);
        assert_eq!(stream.sample_rate, 48_000);
    }

    #[cfg(feature = "wav")]
    #[test]
    fn source_byte_length_counts_resident_bytes() {
        let bytes = std::fs::read(format!("{FIXTURES}tone.wav")).unwrap();
        let memory = FrustbiteAudio::open_memory(&bytes, None).unwrap();
        assert_eq!(memory.byte_length(), bytes.len());
        assert_eq!(open("tone.wav").unwrap().byte_length(), 0);
        // The file's bitrate still uses the on-disk size.
        assert!(open("tone.wav").unwrap().data_size > 0);
    }
}
