//! A child process that plays a script: the lines it prints, whether it has closed, and a record of what it was sent.

use super::{ChildProcess, LaunchSpec, ProcessLauncher, ReadResult};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Debug, Default)]
pub struct Script {
    pub output: VecDeque<String>,
    /// Once the output is drained, a closed script reports `Closed` and an open one reports `Pending`.
    pub closed: bool,
    pub exit_status: i32,
    pub refuse_input: bool,
    pub written: Vec<String>,
    pub interrupts: usize,
    pub killed: bool,
    pub launches: Vec<LaunchSpec>,
}

pub type SharedScript = Arc<Mutex<Script>>;

pub fn shared_script() -> SharedScript {
    Arc::new(Mutex::new(Script::default()))
}

/// Locks the script for a test. A poisoned lock is still readable here, since a test failure is the only way to
/// poison it.
pub fn lock(script: &SharedScript) -> MutexGuard<'_, Script> {
    script.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub fn push_lines<S: AsRef<str>>(script: &SharedScript, lines: &[S]) {
    lock(script).output.extend(lines.iter().map(|line| line.as_ref().to_owned()));
}

pub struct ScriptedChild {
    script: SharedScript,
}

impl ChildProcess for ScriptedChild {
    fn write_line(&mut self, line: &str) -> bool {
        let mut script = lock(&self.script);
        if script.refuse_input {
            return false;
        }
        script.written.push(line.to_owned());
        true
    }

    fn read_line(&mut self) -> ReadResult {
        let mut script = lock(&self.script);
        if let Some(line) = script.output.pop_front() {
            return ReadResult::Line(line);
        }
        if script.closed {
            ReadResult::Closed
        } else {
            ReadResult::Pending
        }
    }

    fn interrupt(&mut self) {
        lock(&self.script).interrupts += 1;
    }

    fn kill(&mut self) {
        let mut script = lock(&self.script);
        script.killed = true;
        script.closed = true;
    }

    fn exit_status(&mut self) -> Option<i32> {
        let script = lock(&self.script);
        script.closed.then_some(script.exit_status)
    }
}

pub struct ScriptedLauncher {
    pub script: SharedScript,
}

impl ScriptedLauncher {
    pub fn new(script: &SharedScript) -> Self {
        Self {
            script: Arc::clone(script),
        }
    }
}

impl ProcessLauncher for ScriptedLauncher {
    fn spawn(&mut self, command: LaunchSpec) -> Box<dyn ChildProcess> {
        lock(&self.script).launches.push(command);
        Box::new(ScriptedChild {
            script: Arc::clone(&self.script),
        })
    }
}
