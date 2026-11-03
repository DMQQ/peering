//! Runs git with an argument list, never through a shell, reading no more than a limit and stopping at a timeout.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use super::{GitOutput, GitRun, GitRunner};
use crate::process_tree::ProcessTree;

/// Switched off because a repository's own config may name a program for each, and looking must not run one.
const SAFETY_OPTIONS: [&str; 4] = ["-c", "core.fsmonitor=false", "-c", "core.quotepath=false"];
const WAIT_STEP: Duration = Duration::from_millis(10);

pub struct ProcessGit {
    executable: PathBuf,
}

impl ProcessGit {
    /// `None` when no git can be found.
    pub fn find() -> Option<Self> {
        let executable = super::locator::executable(|name| std::env::var(name).ok(), Path::is_file)?;
        Some(Self { executable })
    }

    fn command(&self, run: &GitRun<'_>, directory: &Path) -> Command {
        let mut command = Command::new(&self.executable);
        command
            .args(SAFETY_OPTIONS)
            .args(run.arguments)
            .current_dir(directory)
            .env("LC_ALL", "C")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GCM_INTERACTIVE", "never")
            .env("GIT_PAGER", "cat")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(if run.writes { Stdio::piped() } else { Stdio::null() });
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        command
    }
}

impl GitRunner for ProcessGit {
    fn run(&self, run: GitRun<'_>, directory: &Path) -> Option<GitOutput> {
        let mut child = self.command(&run, directory).spawn().ok()?;
        let tree = ProcessTree::containing(&child);
        let full = Arc::new(AtomicBool::new(false));
        let out = child.stdout.take().map(|stream| thread::spawn(capped_read(stream, run.limit, full.clone())));
        let err = child.stderr.take().map(|stream| thread::spawn(capped_read(stream, run.limit, full.clone())));
        // A read is cut short at the limit; a write is left to finish, so a commit is never half done.
        let stop_when_full = (!run.writes).then_some(&*full);
        let (exited_cleanly, timed_out) = wait(&mut child, &tree, run.timeout, stop_when_full);
        let mut data = out.and_then(|reader| reader.join().ok()).unwrap_or_default();
        if let Some(text) = err.and_then(|reader| reader.join().ok()) {
            data.extend(text);
        }
        let truncated = full.load(Ordering::Relaxed);
        Some(GitOutput { data, truncated, succeeded: succeeded(run.writes, truncated, exited_cleanly, timed_out) })
    }
}

/// A cut-off read still shows what it got; a write counts only when git finished by itself.
fn succeeded(writes: bool, truncated: bool, exited_cleanly: bool, timed_out: bool) -> bool {
    (truncated && !writes) || (exited_cleanly && !timed_out)
}

/// Whether git exited cleanly, and whether it was stopped for taking too long. A full output also stops a read.
fn wait(child: &mut Child, tree: &ProcessTree, timeout: Duration, stop_when_full: Option<&AtomicBool>) -> (bool, bool) {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return (status.success(), false),
            Ok(None) if stop_when_full.is_some_and(|full| full.load(Ordering::Relaxed)) => {
                tree.stop(child);
                return (false, false);
            }
            Ok(None) if Instant::now() >= deadline => {
                tree.stop(child);
                return (false, true);
            }
            Ok(None) => thread::sleep(WAIT_STEP),
            Err(_) => return (false, false),
        }
    }
}

/// Keeps every byte up to `limit` and reads the rest without keeping it, so git never blocks on a full pipe.
fn capped_read(mut stream: impl Read + Send + 'static, limit: usize, full: Arc<AtomicBool>) -> impl FnOnce() -> Vec<u8> + Send {
    move || {
        let mut data = Vec::new();
        let mut buffer = [0u8; 16 * 1024];
        while let Ok(read) = stream.read(&mut buffer) {
            if read == 0 {
                break;
            }
            let room = limit.saturating_sub(data.len());
            data.extend_from_slice(&buffer[..read.min(room)]);
            if read > room {
                full.store(true, Ordering::Relaxed);
            }
        }
        data
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_write_that_was_cut_off_or_stopped_is_not_a_success() {
        assert!(!succeeded(true, true, false, false));
        assert!(!succeeded(true, false, true, true));
        assert!(succeeded(true, true, true, false));
        assert!(succeeded(false, true, false, false));
    }

    #[test]
    fn output_past_the_limit_is_read_to_the_end_and_dropped() {
        let left = Arc::new(std::sync::Mutex::new(std::io::Cursor::new(vec![7u8; 100_000])));
        let full = Arc::new(AtomicBool::new(false));
        let kept = capped_read(Shared(left.clone()), 10, full.clone())();
        assert_eq!(kept, [7u8; 10]);
        assert!(full.load(Ordering::Relaxed));
        assert_eq!(left.lock().expect("unpoisoned").position(), 100_000);
    }

    struct Shared(Arc<std::sync::Mutex<std::io::Cursor<Vec<u8>>>>);

    impl Read for Shared {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.0.lock().expect("unpoisoned").read(buffer)
        }
    }
}
