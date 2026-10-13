//! Windows API adapters for the host ports. Each module keeps its decisions in pure functions that test on any OS and calls
//! the operating system from a `#[cfg(windows)]` part, so the crate checks with `cargo check --target x86_64-pc-windows-msvc`.
//! This crate must not depend on `ring` (a C build that does not cross compile from a Mac).

pub mod addresses;
pub mod clipboard;
pub mod clipboard_image;
pub mod convert;
pub mod dda;
pub mod dpapi;
pub mod handoff;
pub mod keyboard;
pub mod link;
pub mod mft;
pub mod monitors;
pub mod mouse;
pub mod session_state;
pub mod terminal;
#[cfg(windows)]
pub mod gpu;
#[cfg(windows)]
pub mod services;
#[cfg(windows)]
pub mod system;
