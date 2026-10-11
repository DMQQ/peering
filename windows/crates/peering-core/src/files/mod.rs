//! File browsing over the control channel: a service over a `FileSystem` port, with POSIX shaped virtual paths.

pub mod browse;
pub mod fake;
pub mod path;
mod preview;
pub mod vfs;

#[cfg(test)]
mod tests;
