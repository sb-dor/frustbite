//! Frustbite native audio engine: C ABI consumed by the Dart package.

pub mod error;
pub mod ffi;
#[cfg(target_arch = "wasm32")]
mod wasm_alloc;

#[cfg(test)]
mod tests {
    use super::ffi::frustbite_abi_version;

    #[test]
    fn abi_version_is_one() {
        assert_eq!(frustbite_abi_version(), 1);
    }
}
