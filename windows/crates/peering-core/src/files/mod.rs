//! File browsing over the control channel: a service over a `FileSystem` port, with POSIX shaped virtual paths.

pub mod browse;
pub mod changes;
pub mod disk;
pub mod fake;
pub mod fake_disk;
pub mod path;
mod pieces;
mod preview;
pub mod transfer;
pub mod vfs;

#[cfg(test)]
mod tests;
