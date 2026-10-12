//! Running the system's own command line tools (`reg`, `netsh`): by full path under System32, so a program of the same name
//! earlier on the search path is never run, and with a deadline, so a tool that hangs cannot hold the caller.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const FALLBACK_SYSTEM_ROOT: &str = r"C:\Windows";
const POLL: Duration = Duration::from_millis(25);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolOutcome {
    Succeeded,
    /// The tool ran and reported failure. `None` when it was ended by a signal.
    Failed(Option<i32>),
    TimedOut,
    NotStarted(String),
}

impl ToolOutcome {
    pub fn succeeded(&self) -> bool {
        *self == Self::Succeeded
    }

    /// A short phrase for an error message.
    pub fn describe(&self) -> String {
        match self {
            Self::Succeeded => "it succeeded".to_owned(),
            Self::Failed(Some(code)) => format!("it exited with code {code}"),
            Self::Failed(None) => "it was ended before it finished".to_owned(),
            Self::TimedOut => "it did not finish in time".to_owned(),
            Self::NotStarted(reason) => format!("it could not start: {reason}"),
        }
    }
}

/// `%SystemRoot%\System32\<name>.exe`. A `SystemRoot` that is not an absolute drive path is not trusted.
pub fn system_tool_in(system_root: Option<&str>, name: &str) -> PathBuf {
    let root = system_root.filter(|root| is_drive_path(root)).unwrap_or(FALLBACK_SYSTEM_ROOT);
    PathBuf::from(format!(r"{}\System32\{name}.exe", root.trim_end_matches('\\')))
}

pub fn system_tool(name: &str) -> PathBuf {
    system_tool_in(std::env::var("SystemRoot").ok().as_deref(), name)
}

fn is_drive_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'\\'
}

/// Runs `program` with `arguments`, discarding its output, and waits at most `timeout`. A tool still running at the
/// deadline is killed.
pub fn run<S: AsRef<OsStr>>(program: &Path, arguments: &[S], timeout: Duration) -> ToolOutcome {
    let mut command = Command::new(program);
    command.args(arguments).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    hide_window(&mut command);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => return ToolOutcome::NotStarted(error.to_string()),
    };
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return ToolOutcome::Succeeded,
            Ok(Some(status)) => return ToolOutcome::Failed(status.code()),
            Ok(None) if Instant::now() >= deadline => {
                // The process may have ended between the check and the kill; either way it is gone afterwards.
                let _killed = child.kill();
                let _reaped = child.wait();
                return ToolOutcome::TimedOut;
            }
            Ok(None) => std::thread::sleep(POLL),
            Err(error) => return ToolOutcome::NotStarted(error.to_string()),
        }
    }
}

/// A console tool started from a window process would flash a console window.
#[cfg(windows)]
fn hide_window(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn hide_window(_command: &mut Command) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_tool_is_named_by_its_full_path_under_the_system_root() {
        assert_eq!(system_tool_in(Some(r"D:\Windows"), "netsh"), PathBuf::from(r"D:\Windows\System32\netsh.exe"));
        assert_eq!(system_tool_in(Some(r"C:\WINDOWS\"), "reg"), PathBuf::from(r"C:\WINDOWS\System32\reg.exe"));
    }

    #[test]
    fn a_missing_or_relative_system_root_falls_back_to_the_default() {
        for root in [None, Some(""), Some("windows"), Some(r"\\server\share"), Some(r"..\evil")] {
            assert_eq!(system_tool_in(root, "reg"), PathBuf::from(r"C:\Windows\System32\reg.exe"), "{root:?}");
        }
    }

    #[test]
    fn describing_an_outcome_names_what_went_wrong() {
        assert_eq!(ToolOutcome::Failed(Some(1)).describe(), "it exited with code 1");
        assert_eq!(ToolOutcome::TimedOut.describe(), "it did not finish in time");
        assert!(ToolOutcome::NotStarted("missing".to_owned()).describe().contains("missing"));
    }

    #[cfg(unix)]
    mod running {
        use super::*;

        const SHELL: &str = "/bin/sh";

        fn sh(script: &str, timeout: Duration) -> ToolOutcome {
            run(Path::new(SHELL), &["-c", script], timeout)
        }

        #[test]
        fn a_tool_that_succeeds_is_reported_as_succeeded() {
            assert_eq!(sh("exit 0", Duration::from_secs(5)), ToolOutcome::Succeeded);
        }

        #[test]
        fn a_tool_that_fails_reports_its_exit_code() {
            assert_eq!(sh("exit 3", Duration::from_secs(5)), ToolOutcome::Failed(Some(3)));
        }

        #[test]
        fn a_tool_that_hangs_is_killed_at_the_deadline() {
            let started = Instant::now();
            assert_eq!(sh("exec sleep 30", Duration::from_millis(200)), ToolOutcome::TimedOut);
            assert!(started.elapsed() < Duration::from_secs(10));
        }

        #[test]
        fn a_tool_that_does_not_exist_is_not_started() {
            let outcome = run(Path::new("/no/such/tool"), &["x"], Duration::from_secs(1));
            assert!(matches!(outcome, ToolOutcome::NotStarted(_)));
        }
    }
}
