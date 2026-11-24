//! C-compatible API surface.
//!
//! Every function catches panics and reports them as `Unknown`. Out-parameters are written
//! only when the result is `Success`.

#[cfg(not(target_arch = "wasm32"))]
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::error::FrustbiteErrorCode;
use crate::probe::{FrustbiteAudio, FrustbiteAudioInfo, FrustbiteContainer};

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

/// Size in bytes of the data behind the handle, for memory accounting. Returns 0 for null.
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

#[cfg(test)]
mod tests {
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
        let mut out: *mut FrustbiteAudio = ptr::null_mut();
        let code = unsafe {
            frustbite_open_memory(
                bytes.as_ptr(),
                bytes.len(),
                FRUSTBITE_FORMAT_DETECT,
                &mut out,
            )
        };
        assert_ne!(code, FrustbiteErrorCode::Success);
        assert!(out.is_null());
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
}
