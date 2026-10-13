//! Shells in a ConPTY pseudo console. What to run and when a shell counts as finished are decided in `environment` and
//! `exit` and tested anywhere; `conpty` and `job` are the only parts that call the operating system.

pub mod environment;
pub mod exit;

#[cfg(windows)]
mod conpty;
#[cfg(windows)]
mod job;

#[cfg(windows)]
pub use conpty::ConPtySpawner;
