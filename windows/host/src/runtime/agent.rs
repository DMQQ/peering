//! Starts agent CLIs as child processes. Output is read on a thread, so a session never blocks on a pipe.

use std::env;
use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use peering_agent::availability::BinaryLocator;
use peering_agent::claude_adapter::{ChildProcess, LaunchSpec, ProcessLauncher, ReadResult};
use peering_agent::codex_session_log;
use peering_agent::process_tree::ProcessTree;
use peering_agent::environment::{find_binary, launch_command, Exists, SearchEnv};

#[derive(Default)]
pub struct StdLauncher;

/// How long a turn's exit code is waited for once its output has closed.
const EXIT_WAIT: Duration = Duration::from_secs(2);
const EXIT_WAIT_STEP: Duration = Duration::from_millis(10);

impl ProcessLauncher for StdLauncher {
    /// A launch that fails returns a child that has already ended, so the adapter reports the session as closed.
    fn spawn(&mut self, command: LaunchSpec) -> Box<dyn ChildProcess> {
        match start(&command) {
            Ok(child) => Box::new(StdChild::new(child, command.input)),
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

/// Codex's own folder, as the CLI finds it.
pub(super) fn codex_home() -> std::path::PathBuf {
    let home = env::var("USERPROFILE").or_else(|_| env::var("HOME")).unwrap_or_default();
    codex_session_log::codex_home(env::var("CODEX_HOME").ok().as_deref(), &home)
}

fn start(command: &LaunchSpec) -> io::Result<Child> {
    let resolved = find_binary(&command.program, &search_env(), &DiskExists)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("{} is not installed", command.program)))?;
    let (program, arguments) = launch_command(&resolved, &command.arguments, &search_env(), &DiskExists)
        .map_err(|refused| io::Error::new(io::ErrorKind::InvalidInput, refused))?;
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

    fn read_text(&self, path: &str) -> Option<String> {
        std::fs::read_to_string(path).ok()
    }
}

struct StdChild {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    /// The CLI and everything it starts (an npm shim's node, Codex's own binary), so a kill reaches them all.
    tree: ProcessTree,
}

impl StdChild {
    fn new(mut child: Child, input: Option<String>) -> Self {
        let tree = ProcessTree::containing(&child);
        let mut stdin = child.stdin.take();
        if let Some(input) = input {
            send_and_close(stdin.take(), input);
        }
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
        Self {
            child,
            stdin,
            lines,
            tree,
        }
    }
}

/// On a thread, because a large prompt fills the pipe before the CLI starts reading.
fn send_and_close(stdin: Option<ChildStdin>, input: String) {
    let Some(mut stdin) = stdin else { return };
    thread::spawn(move || {
        // A CLI that exits before reading its prompt reports that through its exit; the write has nothing to add.
        let _written = stdin.write_all(input.as_bytes());
    });
}

/// The exit code, waiting up to `bound` because output can close a moment before the process is reaped.
fn exit_code_within(child: &mut Child, bound: Duration) -> Option<i32> {
    let deadline = Instant::now() + bound;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.code(),
            Ok(None) if Instant::now() < deadline => thread::sleep(EXIT_WAIT_STEP),
            _ => return None,
        }
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
        self.tree.stop(&mut self.child);
    }

    fn exit_status(&mut self) -> Option<i32> {
        exit_code_within(&mut self.child, EXIT_WAIT)
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn the_exit_code_is_waited_for_after_output_closes() {
        let mut child = Command::new("sh").args(["-c", "exec 1>&-; sleep 0.2; exit 3"]).stdout(Stdio::piped()).spawn().expect("sh");
        assert_eq!(exit_code_within(&mut child, EXIT_WAIT), Some(3));
    }

    #[test]
    fn a_prompt_sent_on_stdin_reaches_the_process_and_ends_its_input() {
        let child = Command::new("sh").args(["-c", "cat"]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().expect("sh");
        let mut session = StdChild::new(child, Some("a \" & calc & \"\n".to_owned()));
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut lines = Vec::new();
        while Instant::now() < deadline {
            match session.read_line() {
                ReadResult::Line(line) => lines.push(line),
                ReadResult::Pending => thread::sleep(EXIT_WAIT_STEP),
                ReadResult::Closed => break,
            }
        }
        assert_eq!(lines, ["a \" & calc & \""]);
        assert_eq!(session.exit_status(), Some(0));
    }
}
