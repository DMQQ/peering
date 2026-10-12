//! A shell the test controls: it echoes what it is sent, prints what the test tells it to, and exits when told.

use std::collections::VecDeque;
use std::io;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use super::pty::{Pty, PtyRead, PtySpawner, SpawnRequest};

#[derive(Debug, Default)]
pub struct FakeShellState {
    pub written: Vec<u8>,
    pub columns: u16,
    pub rows: u16,
    pub directory: String,
    pub program: String,
    pub killed: bool,
    pub exit_code: Option<i32>,
    pub fail_writes: bool,
    output: VecDeque<Vec<u8>>,
}

/// The test's end of one fake shell.
#[derive(Clone, Default)]
pub struct FakeShell(Arc<Mutex<FakeShellState>>);

impl FakeShell {
    pub fn state(&self) -> MutexGuard<'_, FakeShellState> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn print(&self, bytes: &[u8]) {
        self.state().output.push_back(bytes.to_vec());
    }

    pub fn exit(&self, code: i32) {
        self.state().exit_code = Some(code);
    }
}

struct FakePty(FakeShell);

impl Pty for FakePty {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        let mut state = self.0.state();
        if state.fail_writes {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "the shell is gone"));
        }
        state.written.extend_from_slice(data);
        state.output.push_back(data.to_vec());
        Ok(())
    }

    fn resize(&mut self, columns: u16, rows: u16) -> io::Result<()> {
        let mut state = self.0.state();
        state.columns = columns;
        state.rows = rows;
        Ok(())
    }

    fn read(&mut self) -> PtyRead {
        let mut state = self.0.state();
        match state.output.pop_front() {
            Some(bytes) => PtyRead::Data(bytes),
            None if state.exit_code.is_some() || state.killed => PtyRead::Closed,
            None => PtyRead::Pending,
        }
    }

    fn kill(&mut self) {
        self.0.state().killed = true;
    }

    fn exit_status(&mut self) -> Option<i32> {
        let state = self.0.state();
        if !state.output.is_empty() {
            return None;
        }
        state.exit_code.or(state.killed.then_some(1))
    }
}

/// Starts fake shells and keeps a handle to each, in the order they were started.
#[derive(Clone, Default)]
pub struct FakeSpawner {
    shells: Arc<Mutex<Vec<FakeShell>>>,
    fail: Arc<Mutex<bool>>,
}

impl FakeSpawner {
    pub fn shell(&self, index: usize) -> FakeShell {
        self.shells.lock().unwrap_or_else(PoisonError::into_inner)[index].clone()
    }

    pub fn started(&self) -> usize {
        self.shells.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    pub fn refuse_to_start(&self) {
        *self.fail.lock().unwrap_or_else(PoisonError::into_inner) = true;
    }
}

impl PtySpawner for FakeSpawner {
    fn spawn(&mut self, request: &SpawnRequest<'_>) -> io::Result<Box<dyn Pty>> {
        if *self.fail.lock().unwrap_or_else(PoisonError::into_inner) {
            return Err(io::Error::new(io::ErrorKind::NotFound, "no shell"));
        }
        let shell = FakeShell::default();
        {
            let mut state = shell.state();
            state.columns = request.columns;
            state.rows = request.rows;
            state.directory = request.directory.to_owned();
            state.program = request.shell.program.clone();
        }
        self.shells.lock().unwrap_or_else(PoisonError::into_inner).push(shell.clone());
        Ok(Box::new(FakePty(shell)))
    }
}
