// Contains MIT-licensed third-party code; see THIRD_PARTY_LICENSES.md.
//
// Linker flags for the cdylib. They are set here and not through
// CARGO_TARGET_<TRIPLE>_RUSTFLAGS or `.cargo/config.toml`: a user's RUSTFLAGS or
// CARGO_ENCODED_RUSTFLAGS would silently replace those.
fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match os.as_str() {
        // Google Play requires 16 KB page alignment.
        "android" => println!("cargo:rustc-cdylib-link-arg=-Wl,-z,max-page-size=16384"),
        // Room for install_name_tool (Flutter and Dart tooling rewrite the install
        // name when they bundle the dylib), and a relocatable install name.
        "macos" | "ios" => {
            println!("cargo:rustc-cdylib-link-arg=-Wl,-headerpad_max_install_names");
            println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libfrustbite.dylib");
        }
        // No libgcc_s.so.1 at run time: minimal images (scratch, distroless) lack it.
        "linux" => println!("cargo:rustc-cdylib-link-arg=-static-libgcc"),
        _ => {}
    }
    println!("cargo:rerun-if-changed=build.rs");
}
