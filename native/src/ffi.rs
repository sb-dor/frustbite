//! C-compatible API surface.

/// ABI contract version. Increment for incompatible signatures, layouts, or IDs.
#[unsafe(no_mangle)]
pub extern "C" fn frustbite_abi_version() -> u32 {
    1
}
