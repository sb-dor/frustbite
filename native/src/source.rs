//! Audio sources: bytes in memory or a file on disk.
//!
//! A source is immutable. Every operation opens its own `MediaSourceStream`, so a
//! handle can be shared between threads and read more than once.

use std::io::Cursor;
use std::path::PathBuf;
use std::sync::Arc;

use symphonia::core::formats::probe::Hint;
use symphonia::core::io::{MediaSource, MediaSourceStream, MediaSourceStreamOptions};

use crate::error::FrustbiteErrorCode;
use crate::probe::FrustbiteContainer;

/// Reference-counted bytes usable as a `Cursor` buffer.
#[derive(Clone)]
struct SharedBytes(Arc<[u8]>);

impl AsRef<[u8]> for SharedBytes {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

/// Where the audio bytes come from.
#[derive(Clone)]
pub enum AudioSource {
    /// A private copy of the bytes.
    Memory(Arc<[u8]>),
    /// A file, read on demand.
    File(PathBuf),
}

impl AudioSource {
    /// Size of the underlying data in bytes.
    pub fn byte_length(&self) -> usize {
        match self {
            Self::Memory(bytes) => bytes.len(),
            Self::File(path) => std::fs::metadata(path)
                .map(|meta| usize::try_from(meta.len()).unwrap_or(usize::MAX))
                .unwrap_or(0),
        }
    }

    /// Opens a fresh stream positioned at the start.
    pub fn open_stream(&self) -> Result<MediaSourceStream<'static>, FrustbiteErrorCode> {
        let source: Box<dyn MediaSource> = match self {
            Self::Memory(bytes) => Box::new(Cursor::new(SharedBytes(Arc::clone(bytes)))),
            Self::File(path) => {
                Box::new(std::fs::File::open(path).map_err(|_| FrustbiteErrorCode::InvalidPath)?)
            }
        };
        Ok(MediaSourceStream::new(
            source,
            MediaSourceStreamOptions::default(),
        ))
    }

    /// Builds the probe hint from the caller's container and, for files, the extension.
    pub fn hint(&self, container: Option<FrustbiteContainer>) -> Hint {
        let mut hint = Hint::new();
        if let Some(container) = container {
            hint.with_extension(container.extension());
        } else if let Self::File(path) = self
            && let Some(extension) = path.extension().and_then(|ext| ext.to_str())
        {
            hint.with_extension(extension);
        }
        hint
    }
}
