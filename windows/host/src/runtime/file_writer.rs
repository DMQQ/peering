//! Runs the file writes on a thread of their own, one job at a time in the order they arrived. Pieces of an upload must reach
//! the disk in order, and a slow disk or a network drive must not hold up the pictures, so neither the runtime thread nor the
//! blocking pool does this work.

use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use peering_core::files::changes::change;
use peering_core::files::disk::DiskOps;
use peering_core::files::transfer::{QueuedByteBudget, Transfers, DISK_BEHIND};
use peering_wire::files::RemoteFileOperation;
use peering_wire::terminal::{TerminalEvent, TerminalRequest};


/// How often a transfer that has gone quiet is looked for.
const IDLE_CHECK: Duration = Duration::from_secs(30);
const UNAVAILABLE: &str = "File transfers are not available on this PC right now.";

/// Where an answer goes. It is called on the writer's thread.
pub type Reply = Arc<dyn Fn(TerminalEvent) + Send + Sync>;

enum Job {
    Begin { reply: Reply, session_id: String, path: String, total_bytes: i64 },
    Piece { reply: Reply, session_id: String, path: String, data: Vec<u8>, is_last: bool },
    Stop { reply: Reply, session_id: String, path: String },
    Change { reply: Reply, session_id: String, operation: RemoteFileOperation },
}

pub struct FileWriter {
    jobs: Sender<Job>,
    budget: Arc<Mutex<QueuedByteBudget>>,
    /// Joined by nobody: the thread ends when the last sender is dropped, which is when the host state goes.
    _thread: JoinHandle<()>,
}

impl FileWriter {
    pub fn start(disk: Box<dyn DiskOps + Send>, new_id: Box<dyn FnMut() -> String + Send>) -> std::io::Result<Self> {
        let (jobs, inbox) = channel();
        let budget = Arc::new(Mutex::new(QueuedByteBudget::default()));
        let worker_budget = budget.clone();
        let transfers = Transfers::new(disk, new_id);
        let thread = thread::Builder::new().name("file-writer".to_owned()).spawn(move || work(transfers, &inbox, &worker_budget))?;
        Ok(Self { jobs, budget, _thread: thread })
    }

    /// Hands a write request to the writer. False for a request that is not a write, which the caller answers itself.
    pub fn submit(&self, request: &TerminalRequest, reply: &Reply) -> bool {
        let fallback = reply.clone();
        let reply = reply.clone();
        let job = match request {
            TerminalRequest::BeginWrite { session_id, path, total_bytes } => {
                Job::Begin { reply, session_id: session_id.clone(), path: path.clone(), total_bytes: *total_bytes }
            }
            TerminalRequest::WriteChunk { session_id, path, data, is_last } => {
                if !self.reserve(data.len()) {
                    Job::Stop { reply, session_id: session_id.clone(), path: path.clone() }
                } else {
                    Job::Piece { reply, session_id: session_id.clone(), path: path.clone(), data: data.clone(), is_last: *is_last }
                }
            }
            TerminalRequest::ChangeFile { session_id, operation } => {
                Job::Change { reply, session_id: session_id.clone(), operation: operation.clone() }
            }
            _ => return false,
        };
        if let Err(undelivered) = self.jobs.send(job) {
            release_piece(&self.budget, &undelivered.0);
            if let Some(event) = unavailable(request) {
                fallback(event);
            }
        }
        true
    }

    fn reserve(&self, bytes: usize) -> bool {
        self.budget.lock().unwrap_or_else(PoisonError::into_inner).reserve(bytes)
    }
}

fn release_piece(budget: &Mutex<QueuedByteBudget>, job: &Job) {
    if let Job::Piece { data, .. } = job {
        budget.lock().unwrap_or_else(PoisonError::into_inner).release(data.len());
    }
}

/// The writer is gone, so the request is answered as the failure it is and not left unanswered.
fn unavailable(request: &TerminalRequest) -> Option<TerminalEvent> {
    match request {
        TerminalRequest::ChangeFile { session_id, operation } => Some(TerminalEvent::FileOperationFailure {
            session_id: session_id.clone(),
            path: operation_path(operation).to_owned(),
            message: UNAVAILABLE.to_owned(),
        }),
        TerminalRequest::BeginWrite { session_id, path, .. } | TerminalRequest::WriteChunk { session_id, path, .. } => {
            Some(TerminalEvent::WriteFailure { session_id: session_id.clone(), path: path.clone(), message: UNAVAILABLE.to_owned() })
        }
        _ => None,
    }
}

fn operation_path(operation: &RemoteFileOperation) -> &str {
    match operation {
        RemoteFileOperation::Create { path, .. } | RemoteFileOperation::Rename { path, .. } | RemoteFileOperation::Delete { path } => path,
    }
}

fn work(mut transfers: Transfers<Box<dyn DiskOps + Send>, Reply>, inbox: &Receiver<Job>, budget: &Mutex<QueuedByteBudget>) {
    transfers.disk().sweep_orphans();
    let started = Instant::now();
    loop {
        match inbox.recv_timeout(IDLE_CHECK) {
            Ok(job) => run(&mut transfers, job, budget, started.elapsed().as_secs_f64()),
            Err(RecvTimeoutError::Timeout) => {
                for (reply, event) in transfers.drop_idle(started.elapsed().as_secs_f64()) {
                    reply(event);
                }
            }
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

fn run(transfers: &mut Transfers<Box<dyn DiskOps + Send>, Reply>, job: Job, budget: &Mutex<QueuedByteBudget>, now: f64) {
    match job {
        Job::Begin { reply, session_id, path, total_bytes } => {
            if let Some(event) = transfers.begin(reply.clone(), &session_id, &path, total_bytes, now) {
                reply(event);
            }
        }
        Job::Piece { reply, session_id, path, data, is_last } => {
            let event = transfers.write(&session_id, &path, &data, is_last, now);
            budget.lock().unwrap_or_else(PoisonError::into_inner).release(data.len());
            if let Some(event) = event {
                reply(event);
            }
        }
        Job::Stop { reply, session_id, path } => reply(transfers.stop(&session_id, &path, DISK_BEHIND)),
        Job::Change { reply, session_id, operation } => reply(change(transfers.disk(), &session_id, &operation)),
    }
}

#[cfg(test)]
mod tests;
