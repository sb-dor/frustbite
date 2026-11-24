//! Linear-memory allocation helpers for WebAssembly callers.

use std::alloc::{Layout, alloc, dealloc};

/// Allocate aligned linear memory for WebAssembly callers.
#[unsafe(no_mangle)]
pub extern "C" fn frustbite_alloc(size: usize, align: usize) -> *mut u8 {
    let Ok(layout) = Layout::from_size_align(size, align) else {
        return std::ptr::null_mut();
    };
    if layout.size() == 0 {
        return std::ptr::null_mut();
    }
    unsafe { alloc(layout) }
}

/// Free linear memory allocated by `frustbite_alloc`.
#[unsafe(no_mangle)]
pub extern "C" fn frustbite_dealloc(ptr: *mut u8, size: usize, align: usize) {
    if ptr.is_null() || size == 0 {
        return;
    }
    if let Ok(layout) = Layout::from_size_align(size, align) {
        unsafe { dealloc(ptr, layout) };
    }
}
