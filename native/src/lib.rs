//! Frustbite native audio engine: C ABI consumed by the Dart package.

mod codecs;
pub mod decode;
pub mod error;
pub mod ffi;
#[cfg(feature = "opus")]
mod opus;
pub mod probe;
mod source;
#[cfg(target_arch = "wasm32")]
mod wasm_alloc;
pub mod waveform;
