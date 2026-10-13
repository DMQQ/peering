//! The `Pty` port over a ConPTY pseudo console, through `portable-pty`. Reading and writing happen on threads, so
//! `read` and `write` never wait on a console.

use std::io::{self, Read, Write};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::thread;
use std::time::Instant;

use peering_core::terminal::pty::{Pty, PtyRead, PtySpawner, SpawnRequest};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};

use super::exit::ExitTracker;
use super::job::Job;

const READ_BYTES: usize = 16 * 1024;

#[derive(Default)]
pub struct ConPtySpawner;

impl PtySpawner for ConPtySpawner {
    fn spawn(&mut self, request: &SpawnRequest<'_>) -> io::Result<Box<dyn Pty>> {
        let size = PtySize { rows: request.rows, cols: request.columns, pixel_width: 0, pixel_height: 0 };
        let pair = native_pty_system().openpty(size).map_err(to_io)?;
        let mut command = CommandBuilder::new(&request.shell.program);
        command.args(&request.shell.arguments);
        command.cwd(request.directory);
        command.env_clear();
        for (name, value) in request.environment {
            command.env(name, value);
        }
        let child = pair.slave.spawn_command(command).map_err(to_io)?;
        drop(pair.slave);
        let job = child.as_raw_handle().and_then(Job::containing);
        let output = start_reader(pair.master.try_clone_reader().map_err(to_io)?);
        let input = start_writer(pair.master.take_writer().map_err(to_io)?);
        Ok(Box::new(ConPty {
            master: pair.master,
            child,
            job,
            input,
            output,
            tracker: ExitTracker::default(),
            output_closed: false,
            started: Instant::now(),
        }))
    }
}

fn start_reader(mut reader: Box<dyn Read + Send>) -> Receiver<Vec<u8>> {
    let (sender, output) = mpsc::channel();
    thread::spawn(move || {
        let mut buffer = vec![0u8; READ_BYTES];
        while let Ok(count) = reader.read(&mut buffer) {
            if count == 0 || sender.send(buffer[..count].to_vec()).is_err() {
                break;
            }
        }
    });
    output
}

fn start_writer(mut writer: Box<dyn Write + Send>) -> Sender<Vec<u8>> {
    let (input, queue) = mpsc::channel::<Vec<u8>>();
    thread::spawn(move || {
        for bytes in queue {
            if writer.write_all(&bytes).and_then(|()| writer.flush()).is_err() {
                break;
            }
        }
    });
    input
}

struct ConPty {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    job: Option<Job>,
    input: Sender<Vec<u8>>,
    output: Receiver<Vec<u8>>,
    tracker: ExitTracker,
    output_closed: bool,
    started: Instant,
}

impl ConPty {
    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    fn look_for_exit(&mut self) {
        if self.tracker.has_exited() {
            return;
        }
        let code = match self.child.try_wait() {
            Ok(Some(status)) => Some(i32::try_from(status.exit_code()).unwrap_or(i32::MAX)),
            Ok(None) | Err(_) => None,
        };
        let now = self.now();
        self.tracker.observe(code, now);
    }
}

impl Pty for ConPty {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.input.send(data.to_vec()).map_err(|_| io::Error::from(io::ErrorKind::BrokenPipe))
    }

    fn resize(&mut self, columns: u16, rows: u16) -> io::Result<()> {
        self.master.resize(PtySize { rows, cols: columns, pixel_width: 0, pixel_height: 0 }).map_err(to_io)
    }

    fn read(&mut self) -> PtyRead {
        match self.output.try_recv() {
            Ok(bytes) => {
                let now = self.now();
                self.tracker.output_arrived(now);
                PtyRead::Data(bytes)
            }
            Err(TryRecvError::Disconnected) => {
                self.output_closed = true;
                PtyRead::Closed
            }
            Err(TryRecvError::Empty) => {
                self.look_for_exit();
                let now = self.now();
                if self.tracker.finished(now, false).is_some() { PtyRead::Closed } else { PtyRead::Pending }
            }
        }
    }

    fn kill(&mut self) {
        // A shell that has already ended cannot be ended again, which is the outcome asked for.
        let _killed = self.child.kill();
        self.job = None;
    }

    fn exit_status(&mut self) -> Option<i32> {
        self.look_for_exit();
        let now = self.now();
        self.tracker.finished(now, self.output_closed)
    }
}

fn to_io(error: impl std::fmt::Display) -> io::Error {
    io::Error::other(error.to_string())
}
