//! The port a shell runs behind. `peering-platform` implements it with a pseudo console; `fake` implements it for tests.

use std::io;

use super::shell::Shell;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PtyRead {
    Data(Vec<u8>),
    /// Nothing to read now, but the shell may still print.
    Pending,
    /// The shell has ended and everything it printed has been read.
    Closed,
}

/// One running shell. Every call returns at once; `read` never waits for output.
pub trait Pty: Send {
    fn write(&mut self, data: &[u8]) -> io::Result<()>;
    fn resize(&mut self, columns: u16, rows: u16) -> io::Result<()>;
    fn read(&mut self) -> PtyRead;
    /// Ends the shell and everything it started. A shell that has already ended is not an error.
    fn kill(&mut self);
    /// The exit code once the shell has ended and its output has been delivered by `read`.
    fn exit_status(&mut self) -> Option<i32>;
}

pub struct SpawnRequest<'a> {
    pub shell: &'a Shell,
    pub directory: &'a str,
    pub environment: &'a [(String, String)],
    pub columns: u16,
    pub rows: u16,
}

pub trait PtySpawner: Send {
    fn spawn(&mut self, request: &SpawnRequest<'_>) -> io::Result<Box<dyn Pty>>;
}
