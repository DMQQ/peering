//! Names the build's version for the update check, and embeds `app.manifest` (per-monitor DPI v2, asInvoker, long paths, Windows 10 and 11) into the Windows executable.
//! Other targets have no resources to embed, so the script only names the version for them.

use std::env;

fn main() {
    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=PEERING_RELEASE_TAG");
    println!("cargo:rustc-env=PEERING_HOST_VERSION={}", build_version());
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        #[cfg(windows)]
        embed_manifest();
    }
}

/// The release tag's version when the build is for a release (`windows-v0.2.0` is 0.2.0), else the crate's own. The installer
/// takes its version from the same tag, so the running build and the installer that put it there agree.
fn build_version() -> String {
    let tag = env::var("PEERING_RELEASE_TAG").unwrap_or_default();
    match tag.strip_prefix("windows-v").filter(|version| !version.is_empty()) {
        Some(version) => version.to_owned(),
        None => env::var("CARGO_PKG_VERSION").expect("cargo sets the package version"),
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
