//! Starts agent CLIs as child processes. Output is read on a thread, so a session never blocks on a pipe.

use std::env;
use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;

use peering_agent::availability::BinaryLocator;
use peering_agent::claude_adapter::{ChildProcess, LaunchSpec, ProcessLauncher, ReadResult};
use peering_agent::environment::{find_binary, launch_command, Exists, SearchEnv};

#[derive(Default)]
pub struct StdLauncher;

impl ProcessLauncher for StdLauncher {
    /// A launch that fails returns a child that has already ended, so the adapter reports the session as closed.
    fn spawn(&mut self, command: LaunchSpec) -> Box<dyn ChildProcess> {
        match start(&command) {
            Ok(child) => Box::new(StdChild::new(child)),
            Err(_) => Box::new(EndedChild),
        }
    }
}

/// Where agent CLIs are looked for, from this process's environment.
pub(super) fn search_env() -> SearchEnv {
    let path = env::var("PATH").unwrap_or_default();
    let path_ext = env::var("PATHEXT").ok();
    let user_profile = env::var("USERPROFILE").unwrap_or_default();
    let app_data = env::var("APPDATA").ok();
    SearchEnv::new(&path, path_ext.as_deref(), &user_profile, app_data.as_deref())
}

fn start(command: &LaunchSpec) -> io::Result<Child> {
    let resolved = find_binary(&command.program, &search_env(), &DiskExists)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("{} is not installed", command.program)))?;
    let (program, arguments) = launch_command(&resolved, &command.arguments);
    let mut process = Command::new(program);
    process
        .args(arguments)
        .current_dir(&command.directory)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    hide_console(&mut process);
    process.spawn()
}

/// An agent CLI is a console program, and started from the windowless host it would open a black terminal beside the chat.
#[cfg(windows)]
fn hide_console(process: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    process.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn hide_console(_process: &mut Command) {}

/// Looks for the agent CLI the way a launch would.
pub(super) struct DiskBinaries;

impl BinaryLocator for DiskBinaries {
    fn is_installed(&self, program: &str) -> bool {
        find_binary(program, &search_env(), &DiskExists).is_some()
    }
}

pub(super) struct DiskExists;

impl Exists for DiskExists {
    fn exists(&self, path: &str) -> bool {
        std::path::Path::new(path).is_file()
    }
}

struct StdChild {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
}

impl StdChild {
    fn new(mut child: Child) -> Self {
        let stdin = child.stdin.take();
        let (sender, lines) = mpsc::channel();
        if let Some(stdout) = child.stdout.take() {
            thread::spawn(move || {
                for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                    if sender.send(line).is_err() {
                        break;
                    }
                }
            });
        }
        Self { child, stdin, lines }
    }
}

impl ChildProcess for StdChild {
    fn write_line(&mut self, line: &str) -> bool {
        let Some(stdin) = self.stdin.as_mut() else {
            return false;
        };
        writeln!(stdin, "{line}").and_then(|()| stdin.flush()).is_ok()
    }

    fn read_line(&mut self) -> ReadResult {
        match self.lines.try_recv() {
            Ok(line) => ReadResult::Line(line),
            Err(TryRecvError::Empty) => ReadResult::Pending,
            Err(TryRecvError::Disconnected) => ReadResult::Closed,
        }
    }

    /// Windows has no portable signal to a child process, so an interrupt ends it. The Claude adapter interrupts
    /// through its control request and does not call this.
    fn interrupt(&mut self) {
        self.kill();
    }

    fn kill(&mut self) {
        // A child that already exited cannot be killed again, which is the outcome asked for.
        let _killed = self.child.kill();
    }

    fn exit_status(&mut self) -> Option<i32> {
        self.child.try_wait().ok().flatten().and_then(|status| status.code())
    }
}

struct EndedChild;

impl ChildProcess for EndedChild {
    fn write_line(&mut self, _line: &str) -> bool {
        false
    }

    fn read_line(&mut self) -> ReadResult {
        ReadResult::Closed
    }

    fn interrupt(&mut self) {}

    fn kill(&mut self) {}

    fn exit_status(&mut self) -> Option<i32> {
        Some(-1)
    }
}
