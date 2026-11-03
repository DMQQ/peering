//! Shells in a ConPTY pseudo console. What to run and when a shell counts as finished are decided in `environment` and
//! `exit` and tested anywhere; `conpty` (with `crate::job`) is the only part that calls the operating system.

pub mod environment;
pub mod exit;

#[cfg(windows)]
mod conpty;

#[cfg(windows)]
pub use conpty::ConPtySpawner;
