//! Error codes shared with the Dart side.

/// Result of every fallible Frustbite function.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum FrustbiteErrorCode {
    /// The operation succeeded.
    Success = 0,
    /// The provided path is empty, malformed, or refers to a non-existent file.
    InvalidPath = 1,
    /// The audio format is not recognised or not supported by this build.
    UnsupportedFormat = 2,
    /// The audio bytes are corrupt or do not match the expected format.
    DecodingError = 3,
    /// An underlying I/O operation (read/write) failed.
    IoError = 4,
    /// A handle or output pointer was null, or the handle has been freed.
    InvalidPointer = 5,
    /// A scalar parameter is out of range.
    InvalidParameter = 6,
    // 7 is reserved for `EncodingError` (stage 3).
    /// An unclassified error occurred.
    Unknown = 99,
}
