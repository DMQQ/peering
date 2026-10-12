//! Embeds `app.manifest` (per-monitor DPI v2, asInvoker, long paths, Windows 10 and 11) into the Windows executable.
//! Other targets have no resources to embed, so the script does nothing for them.

use std::env;

fn main() {
    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rerun-if-changed=build.rs");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        #[cfg(windows)]
        embed_manifest();
    }
}

/// The embed needs the Windows resource compiler, which only the Windows build machine has. A Windows target built
/// from another machine is linked without the manifest.
#[cfg(windows)]
fn embed_manifest() {
    use std::path::PathBuf;

    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets the manifest directory"))
        .join("app.manifest");
    let script = PathBuf::from(env::var("OUT_DIR").expect("cargo sets the output directory")).join("app.rc");
    let manifest_path = manifest.display().to_string().replace('\\', "\\\\");
    std::fs::write(&script, format!("1 24 \"{manifest_path}\"\n")).expect("the resource script is writable");
    embed_resource::compile(&script, embed_resource::NONE).manifest_required().expect("the manifest is embedded");
}
