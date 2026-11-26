//! Frustbite native audio engine: C ABI consumed by the Dart package.

mod codecs;
pub mod decode;
pub mod edit;
pub mod error;
pub mod ffi;
#[cfg(feature = "opus")]
mod opus;
pub mod probe;
pub mod silence;
mod source;
mod tags;
#[cfg(target_arch = "wasm32")]
mod wasm_alloc;
pub mod wav;
pub mod waveform;
