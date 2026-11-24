//! C-compatible API surface.
//!
//! Every function catches panics and reports them as `Unknown`. Out-parameters are written
//! only when the result is `Success`.

#[cfg(not(target_arch = "wasm32"))]
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::error::FrustbiteErrorCode;
use crate::probe::{FrustbiteAudio, FrustbiteAudioInfo, FrustbiteContainer};
use crate::waveform::FrustbiteWaveformMode;

/// ABI contract version. Increment for incompatible signatures, layouts, or IDs.
pub const FRUSTBITE_ABI_VERSION: u32 = 1;

/// Returns `FRUSTBITE_ABI_VERSION`, so the Dart side can refuse a mismatched library.
#[unsafe(no_mangle)]
pub extern "C" fn frustbite_abi_version() -> u32 {
    FRUSTBITE_ABI_VERSION
}

/// Runs `body`, turning a panic into `Unknown`.
fn guarded(body: impl FnOnce() -> FrustbiteErrorCode) -> FrustbiteErrorCode {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(FrustbiteErrorCode::Unknown)
}

/// Stores the result of an open operation in `out`.
///
/// # Safety
/// `out` must be valid for a pointer write.
unsafe fn publish(
    result: Result<FrustbiteAudio, FrustbiteErrorCode>,
    out: *mut *mut FrustbiteAudio,
) -> FrustbiteErrorCode {
    match result {
        Ok(audio) => {
            unsafe { out.write(Box::into_raw(Box::new(audio))) };
            FrustbiteErrorCode::Success
        }
        Err(code) => code,
    }
}

/// Opens audio from memory. The bytes are copied. `format` is a `FrustbiteContainer` value or
/// `FRUSTBITE_FORMAT_DETECT`. On success `*out` receives a handle to release with
/// `frustbite_free`.
///
/// # Safety
/// `data` must point to `len` readable bytes (it may be null only when `len` is 0, which is
/// rejected as an invalid pointer anyway); `out` must be valid for a pointer write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn frustbite_open_memory(
    data: *const u8,
    len: usize,
    format: u32,
    out: *mut *mut FrustbiteAudio,
) -> FrustbiteErrorCode {
    guarded(|| {
        if data.is_null() || out.is_null() {
            return FrustbiteErrorCode::InvalidPointer;
        }
        let container = match FrustbiteContainer::from_hint(format) {
            Ok(container) => container,
            Err(code) => return code,
        };
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        unsafe { publish(FrustbiteAudio::open_memory(bytes, container), out) }
    })
}

/// Opens audio from a file. `utf8_path` is a NUL-terminated UTF-8 path. Not available on wasm.
///
/// # Safety
/// `utf8_path` must be a valid NUL-terminated string; `out` must be valid for a pointer write.
#[cfg(not(target_arch = "wasm32"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn frustbite_open_file(
    utf8_path: *const c_char,
    format: u32,
    out: *mut *mut FrustbiteAudio,
) -> FrustbiteErrorCode {
    guarded(|| {
        if utf8_path.is_null() || out.is_null() {
            return FrustbiteErrorCode::InvalidPointer;
        }
        let container = match FrustbiteContainer::from_hint(format) {
            Ok(container) => container,
            Err(code) => return code,
        };
        let Ok(path) = unsafe { CStr::from_ptr(utf8_path) }.to_str() else {
            return FrustbiteErrorCode::InvalidPath;
        };
        if path.is_empty() {
            return FrustbiteErrorCode::InvalidPath;
        }
        unsafe { publish(FrustbiteAudio::open_file(path, container), out) }
    })
}

/// Releases a handle. Passing null is a no-op.
///
/// # Safety
/// `audio` must be null or a handle from `frustbite_open_*` that has not been freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn frustbite_free(audio: *mut FrustbiteAudio) {
    if audio.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(audio) })));
}

/// Describes the audio. The result is cached after the first call.
///
/// # Safety
/// `audio` must be a live handle; `out` must be valid for a `FrustbiteAudioInfo` write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn frustbite_get_info(
    audio: *const FrustbiteAudio,
    out: *mut FrustbiteAudioInfo,
) -> FrustbiteErrorCode {
    guarded(|| {
        if audio.is_null() || out.is_null() {
            return FrustbiteErrorCode::InvalidPointer;
        }
        match unsafe { &*audio }.info() {
            Ok(info) => {
                unsafe { out.write(info) };
                FrustbiteErrorCode::Success
            }
            Err(code) => code,
        }
    })
}

/// Bytes the handle keeps in memory, for memory accounting: the copied data for
/// `frustbite_open_memory`, 0 for `frustbite_open_file` (a file handle holds no bytes) and for
/// null. Does no I/O.
///
/// # Safety
/// `audio` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn frustbite_source_byte_length(audio: *const FrustbiteAudio) -> usize {
    if audio.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| unsafe { &*audio }.byte_length())).unwrap_or(0)
}

/// Decodes the whole source to interleaved f32 at its native sample rate and channel count.
///
/// On success `*out_samples` receives a buffer of `*out_len` samples (frames x channels) to
/// release with `frustbite_free_f32` using the same length. A source without any audio frames
/// yields a null `*out_samples` with `*out_len` 0. Decoding is heavy: call it off the UI
/// thread.
///
/// # Safety
/// `audio` must be a live handle; every out-pointer must be valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn frustbite_decode(
    audio: *const FrustbiteAudio,
    out_samples: *mut *mut f32,
    out_len: *mut usize,
    out_sample_rate: *mut u32,
    out_channels: *mut u32,
) -> FrustbiteErrorCode {
    guarded(|| {
        if audio.is_null()
            || out_samples.is_null()
            || out_len.is_null()
            || out_sample_rate.is_null()
            || out_channels.is_null()
        {
            return FrustbiteErrorCode::InvalidPointer;
        }
        match unsafe { &*audio }.decode() {
            Ok(decoded) => {
                let len = decoded.samples.len();
                let ptr = if len == 0 {
                    std::ptr::null_mut()
                } else {
                    Box::into_raw(decoded.samples.into_boxed_slice()).cast::<f32>()
                };
                unsafe {
                    out_samples.write(ptr);
                    out_len.write(len);
                    out_sample_rate.write(decoded.sample_rate);
                    out_channels.write(decoded.channels);
                }
                FrustbiteErrorCode::Success
            }
            Err(code) => code,
        }
    })
}

/// Summarises the whole source into `buckets` amplitudes in [0, 1] for drawing a waveform.
/// `buckets` must be 1..=100000 and `mode` a `FrustbiteWaveformMode` value, else
/// `InvalidParameter`. On success `*out` receives `*out_len` floats, channel-major (all buckets
/// of channel 0, then channel 1, ...; one merged series unless `per_channel`), to release with
/// `frustbite_free_f32` using the same length. Values are absolute full scale, not normalised.
/// Heavy (decodes the whole source): call it off the UI thread.
///
/// # Safety
/// `audio` must be a live handle; `out` and `out_len` must be valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn frustbite_waveform(
    audio: *const FrustbiteAudio,
    buckets: u32,
    mode: u32,
    per_channel: bool,
    out: *mut *mut f32,
    out_len: *mut usize,
) -> FrustbiteErrorCode {
    guarded(|| {
        if audio.is_null() || out.is_null() || out_len.is_null() {
            return FrustbiteErrorCode::InvalidPointer;
        }
        let mode = match FrustbiteWaveformMode::from_u32(mode) {
            Ok(mode) => mode,
            Err(code) => return code,
        };
        match unsafe { &*audio }.waveform(buckets, mode, per_channel) {
            Ok(values) => {
                let len = values.len();
                let ptr = Box::into_raw(values.into_boxed_slice()).cast::<f32>();
                unsafe {
                    out.write(ptr);
                    out_len.write(len);
                }
                FrustbiteErrorCode::Success
            }
            Err(code) => code,
        }
    })
}

/// Releases a buffer from `frustbite_decode` or `frustbite_waveform`. `len` must be the `*out_len` it returned.
/// Passing null is a no-op.
///
/// # Safety
/// `ptr` must be null or a buffer returned by `frustbite_decode` or `frustbite_waveform` with the same `len`, not yet
/// freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn frustbite_free_f32(ptr: *mut f32, len: usize) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }));
}

#[cfg(test)]
pub(crate) mod tests {
    use std::ffi::CString;
    use std::ptr;

    use super::*;
    use crate::probe::FRUSTBITE_FORMAT_DETECT;

    const FIXTURES: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../packages/frustbite/test/fixtures/"
    );

    fn zeroed_info() -> FrustbiteAudioInfo {
        FrustbiteAudioInfo {
            container: 99,
            codec: 99,
            sample_rate: 0,
            channels: 0,
            bits_per_sample: 0,
            bitrate: 0,
            total_frames: 0,
            duration_us: 0,
        }
    }

    #[test]
    fn panic_in_ffi_body_becomes_unknown() {
        // Silence the default panic message for the deliberate panic.
        let hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let code = guarded(|| panic!("simulated decoder panic"));
        std::panic::set_hook(hook);
        assert_eq!(code, FrustbiteErrorCode::Unknown);
    }

    #[test]
    fn abi_version_is_one() {
        assert_eq!(frustbite_abi_version(), 1);
    }

    #[test]
    fn open_null_pointer_is_invalid_pointer() {
        let mut out: *mut FrustbiteAudio = ptr::null_mut();
        unsafe {
            assert_eq!(
                frustbite_open_memory(ptr::null(), 4, FRUSTBITE_FORMAT_DETECT, &mut out),
                FrustbiteErrorCode::InvalidPointer
            );
            let byte = 0u8;
            assert_eq!(
                frustbite_open_memory(&byte, 1, FRUSTBITE_FORMAT_DETECT, ptr::null_mut()),
                FrustbiteErrorCode::InvalidPointer
            );
            assert_eq!(
                frustbite_open_file(ptr::null(), FRUSTBITE_FORMAT_DETECT, &mut out),
                FrustbiteErrorCode::InvalidPointer
            );
            let mut info = zeroed_info();
            assert_eq!(
                frustbite_get_info(ptr::null(), &mut info),
                FrustbiteErrorCode::InvalidPointer
            );
            assert_eq!(frustbite_source_byte_length(ptr::null()), 0);
            frustbite_free(ptr::null_mut());
        }
        assert!(out.is_null());
    }

    #[test]
    fn open_missing_file_is_invalid_path() {
        let path = CString::new(format!("{FIXTURES}missing.wav")).unwrap();
        let mut out: *mut FrustbiteAudio = ptr::null_mut();
        let code = unsafe { frustbite_open_file(path.as_ptr(), FRUSTBITE_FORMAT_DETECT, &mut out) };
        assert_eq!(code, FrustbiteErrorCode::InvalidPath);
        assert!(out.is_null());
    }

    #[test]
    fn open_rejects_unknown_format_value() {
        let path = CString::new(format!("{FIXTURES}tone.wav")).unwrap();
        let mut out: *mut FrustbiteAudio = ptr::null_mut();
        let code = unsafe { frustbite_open_file(path.as_ptr(), 1234, &mut out) };
        assert_eq!(code, FrustbiteErrorCode::InvalidParameter);
    }

    #[test]
    fn failed_open_leaves_out_untouched() {
        let bytes = std::fs::read(format!("{FIXTURES}corrupt.bin")).unwrap();
        let sentinel = 0x1234usize as *mut FrustbiteAudio;
        let mut out = sentinel;
        let code = unsafe {
            frustbite_open_memory(
                bytes.as_ptr(),
                bytes.len(),
                FRUSTBITE_FORMAT_DETECT,
                &mut out,
            )
        };
        assert_ne!(code, FrustbiteErrorCode::Success);
        assert_eq!(out, sentinel);
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn failed_get_info_leaves_out_untouched() {
        // A handle whose info cannot be built: the file vanishes after open, and the duration
        // scan (MP3 without a header) must re-open it.
        let dir = std::env::temp_dir().join(format!("frustbite-ffi-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tone.mp3");
        std::fs::copy(format!("{FIXTURES}tone_vbr_noxing.mp3"), &path).unwrap();
        let c_path = CString::new(path.to_str().unwrap()).unwrap();
        let mut audio: *mut FrustbiteAudio = ptr::null_mut();
        let sentinel = FrustbiteAudioInfo {
            container: 0xAAAA,
            ..zeroed_info()
        };
        let mut info = sentinel;
        unsafe {
            let code = frustbite_open_file(c_path.as_ptr(), FRUSTBITE_FORMAT_DETECT, &mut audio);
            assert_eq!(code, FrustbiteErrorCode::Success);
            std::fs::remove_file(&path).unwrap();
            let code = frustbite_get_info(audio, &mut info);
            assert_eq!(code, FrustbiteErrorCode::InvalidPath);
            assert_eq!(info, sentinel);
            frustbite_free(audio);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn open_info_free_round_trip() {
        let bytes = std::fs::read(format!("{FIXTURES}tone.wav")).unwrap();
        let mut out: *mut FrustbiteAudio = ptr::null_mut();
        let mut info = zeroed_info();
        unsafe {
            let code = frustbite_open_memory(
                bytes.as_ptr(),
                bytes.len(),
                FrustbiteContainer::Wav as u32,
                &mut out,
            );
            assert_eq!(code, FrustbiteErrorCode::Success);
            assert_eq!(frustbite_source_byte_length(out), bytes.len());
            assert_eq!(
                frustbite_get_info(out, &mut info),
                FrustbiteErrorCode::Success
            );
            frustbite_free(out);
        }
        assert_eq!(info.total_frames, 132_300);
    }

    /// A WAV with a valid header and no sample data.
    pub(crate) fn empty_wav() -> Vec<u8> {
        let mut wav = b"RIFF".to_vec();
        wav.extend(36u32.to_le_bytes());
        wav.extend(b"WAVEfmt ");
        wav.extend(16u32.to_le_bytes());
        for field in [1u16, 1] {
            wav.extend(field.to_le_bytes());
        }
        wav.extend(44_100u32.to_le_bytes());
        wav.extend(88_200u32.to_le_bytes());
        for field in [2u16, 16] {
            wav.extend(field.to_le_bytes());
        }
        wav.extend(b"data");
        wav.extend(0u32.to_le_bytes());
        wav
    }

    fn open_bytes(bytes: &[u8]) -> *mut FrustbiteAudio {
        let mut out: *mut FrustbiteAudio = ptr::null_mut();
        let code = unsafe {
            frustbite_open_memory(
                bytes.as_ptr(),
                bytes.len(),
                FRUSTBITE_FORMAT_DETECT,
                &mut out,
            )
        };
        assert_eq!(code, FrustbiteErrorCode::Success);
        out
    }

    #[test]
    fn decode_round_trip() {
        let bytes = std::fs::read(format!("{FIXTURES}tone.wav")).unwrap();
        let audio = open_bytes(&bytes);
        let (mut samples, mut len, mut rate, mut channels) = (ptr::null_mut(), 0usize, 0u32, 0u32);
        unsafe {
            let code = frustbite_decode(audio, &mut samples, &mut len, &mut rate, &mut channels);
            assert_eq!(code, FrustbiteErrorCode::Success);
            assert!(!samples.is_null());
            assert_eq!((len, rate, channels), (132_300 * 2, 44_100, 2));
            assert!(std::slice::from_raw_parts(samples, len)[200].abs() > 0.0);
            frustbite_free_f32(samples, len);
            frustbite_free(audio);
        }
    }

    #[test]
    fn decode_empty_source_returns_null_and_zero_len() {
        let audio = open_bytes(&empty_wav());
        let (mut samples, mut len, mut rate, mut channels) =
            (ptr::dangling_mut::<f32>(), 99usize, 0u32, 0u32);
        unsafe {
            let code = frustbite_decode(audio, &mut samples, &mut len, &mut rate, &mut channels);
            assert_eq!(code, FrustbiteErrorCode::Success);
            assert!(samples.is_null());
            assert_eq!((len, rate, channels), (0, 44_100, 1));
            frustbite_free_f32(samples, len);
            frustbite_free(audio);
        }
    }

    #[test]
    fn decode_null_pointers_are_invalid_pointer() {
        let bytes = std::fs::read(format!("{FIXTURES}click.wav")).unwrap();
        let audio = open_bytes(&bytes);
        let (mut samples, mut len, mut rate, mut channels) = (ptr::null_mut(), 0usize, 0u32, 0u32);
        unsafe {
            let invalid = FrustbiteErrorCode::InvalidPointer;
            assert_eq!(
                frustbite_decode(
                    ptr::null(),
                    &mut samples,
                    &mut len,
                    &mut rate,
                    &mut channels
                ),
                invalid
            );
            assert_eq!(
                frustbite_decode(audio, ptr::null_mut(), &mut len, &mut rate, &mut channels),
                invalid
            );
            assert_eq!(
                frustbite_decode(
                    audio,
                    &mut samples,
                    ptr::null_mut(),
                    &mut rate,
                    &mut channels
                ),
                invalid
            );
            assert_eq!(
                frustbite_decode(
                    audio,
                    &mut samples,
                    &mut len,
                    ptr::null_mut(),
                    &mut channels
                ),
                invalid
            );
            assert_eq!(
                frustbite_decode(audio, &mut samples, &mut len, &mut rate, ptr::null_mut()),
                invalid
            );
            frustbite_free_f32(ptr::null_mut(), 0);
            frustbite_free(audio);
        }
        assert!(samples.is_null());
        assert_eq!((len, rate, channels), (0, 0, 0));
    }

    #[test]
    fn waveform_round_trip() {
        let bytes = std::fs::read(format!("{FIXTURES}tone.wav")).unwrap();
        let audio = open_bytes(&bytes);
        let (mut values, mut len) = (ptr::null_mut(), 0usize);
        unsafe {
            for (per_channel, expected) in [(false, 64), (true, 128)] {
                let code = frustbite_waveform(audio, 64, 0, per_channel, &mut values, &mut len);
                assert_eq!(code, FrustbiteErrorCode::Success);
                assert_eq!(len, expected);
                assert!((0.49..=0.51).contains(&std::slice::from_raw_parts(values, len)[0]));
                frustbite_free_f32(values, len);
            }
            frustbite_free(audio);
        }
    }

    #[test]
    fn waveform_errors_leave_out_untouched() {
        let bytes = std::fs::read(format!("{FIXTURES}click.wav")).unwrap();
        let audio = open_bytes(&bytes);
        let sentinel = 0x1234usize as *mut f32;
        let (mut values, mut len) = (sentinel, 777usize);
        unsafe {
            let cases = [
                (
                    audio.cast_const(),
                    0,
                    0,
                    FrustbiteErrorCode::InvalidParameter,
                ),
                (
                    audio.cast_const(),
                    100_001,
                    0,
                    FrustbiteErrorCode::InvalidParameter,
                ),
                (
                    audio.cast_const(),
                    10,
                    2,
                    FrustbiteErrorCode::InvalidParameter,
                ),
                (ptr::null(), 10, 0, FrustbiteErrorCode::InvalidPointer),
            ];
            for (handle, buckets, mode, expected) in cases {
                let code = frustbite_waveform(handle, buckets, mode, false, &mut values, &mut len);
                assert_eq!(code, expected);
                assert_eq!((values, len), (sentinel, 777));
            }
            let code = frustbite_waveform(audio, 10, 0, false, ptr::null_mut(), &mut len);
            assert_eq!(code, FrustbiteErrorCode::InvalidPointer);
            let code = frustbite_waveform(audio, 10, 0, false, &mut values, ptr::null_mut());
            assert_eq!(code, FrustbiteErrorCode::InvalidPointer);
            assert_eq!((values, len), (sentinel, 777));
            frustbite_free(audio);
        }
    }
}
