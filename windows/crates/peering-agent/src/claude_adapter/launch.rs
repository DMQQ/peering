//! The seam between the adapter and whatever runs the CLI. The adapter speaks lines; the launcher owns the process.

use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchSpec {
    /// The command name. The launcher finds the executable (on Windows, the `.exe` or `.cmd` shim).
    pub program: String,
    pub arguments: Vec<String>,
    pub directory: PathBuf,
}

pub trait ProcessLauncher {
    fn spawn(&mut self, command: LaunchSpec) -> Box<dyn ChildProcess>;
}

pub trait ChildProcess: Send {
    /// False once the process no longer takes input.
    fn write_line(&mut self, line: &str) -> bool;

    fn read_line(&mut self) -> ReadResult;

    /// A signal-level interrupt, for CLIs without a control message. The Claude adapter interrupts through its
    /// control request instead.
    fn interrupt(&mut self);

    fn kill(&mut self);

    /// The exit code once `read_line` has reported `Closed`; `None` while the process still runs.
    fn exit_status(&mut self) -> Option<i32>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadResult {
    Line(String),
    /// Nothing is waiting yet.
    Pending,
    /// The process has ended and its output is drained.
    Closed,
}
