//! The chat's "Changes" review, commit and push. Git runs off the runtime thread; a commit or push is followed by a
//! fresh report, as the Mac host sends one.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use peering_agent::git::{self, process::ProcessGit, GitRunner};
use peering_wire::agent::{AgentChangesReport, AgentEvent, AgentGitOperation, AgentGitResult, AgentRequest};
use peering_wire::framing::{Frame, MessageKind};
use tokio::task::spawn_local;

use super::lock::lock_ignoring_poison;
use super::outbound::FrameSender;

const NO_CHAT: &str = "That chat is no longer here.";
const WRITE_BUSY: &str = "Git is still working in this folder. Try again when it finishes.";

/// The folders a commit or push is running in now. Two at once would race for git's `index.lock`.
#[derive(Clone, Default)]
pub struct GitWrites(Arc<Mutex<HashSet<String>>>);

/// Holds a folder for one write and frees it when dropped.
pub struct WriteClaim {
    writes: GitWrites,
    directory: String,
}

impl GitWrites {
    /// `None` while another write runs in `directory`.
    pub fn claim(&self, directory: &str) -> Option<WriteClaim> {
        let claimed = lock_ignoring_poison(&self.0).insert(directory.to_owned());
        claimed.then(|| WriteClaim { writes: self.clone(), directory: directory.to_owned() })
    }
}

impl Drop for WriteClaim {
    fn drop(&mut self) {
        lock_ignoring_poison(&self.writes.0).remove(&self.directory);
    }
}

/// The git work a request asks for, with the chat's folder.
pub enum GitJob {
    Changes,
    Commit { paths: Vec<String>, message: String },
    Push,
}

impl GitJob {
    /// The job and its chat's id, or `None` for a request that is not about git.
    pub fn of(request: &AgentRequest) -> Option<(String, Self)> {
        match request {
            AgentRequest::Changes { session_id } => Some((session_id.clone(), Self::Changes)),
            AgentRequest::Commit { session_id, paths, message } => {
                Some((session_id.clone(), Self::Commit { paths: paths.clone(), message: message.clone() }))
            }
            AgentRequest::Push { session_id } => Some((session_id.clone(), Self::Push)),
            _ => None,
        }
    }

    fn operation(&self) -> Option<AgentGitOperation> {
        match self {
            Self::Changes => None,
            Self::Commit { .. } => Some(AgentGitOperation::Commit),
            Self::Push => Some(AgentGitOperation::Push),
        }
    }

    fn run(self, git: Option<&dyn GitRunner>, session_id: &str, directory: PathBuf) -> Vec<AgentEvent> {
        let Some(git) = git else {
            let missing = AgentChangesReport::failure(git::locator::MISSING_MESSAGE);
            let operation = match self {
                Self::Changes => return vec![changes(session_id, missing)],
                Self::Commit { .. } => AgentGitOperation::Commit,
                Self::Push => AgentGitOperation::Push,
            };
            let result = AgentGitResult { operation, succeeded: false, message: git::locator::MISSING_MESSAGE.to_owned() };
            return vec![git_result(session_id, &result), changes(session_id, missing)];
        };
        let result = match self {
            Self::Changes => return vec![changes(session_id, git::changes_report(git, &directory))],
            Self::Commit { paths, message } => git::commit(git, &directory, &paths, &message),
            Self::Push => git::push(git, &directory),
        };
        vec![git_result(session_id, &result), changes(session_id, git::changes_report(git, &directory))]
    }
}

/// Runs `job` in `directory` (the chat's own folder, `None` when the chat is not this client's) and sends what it
/// produced to `outbound`. A commit or push is refused while another runs in the same folder.
pub fn answer(session_id: String, job: GitJob, directory: Option<String>, writes: &GitWrites, outbound: FrameSender) {
    let Some(directory) = directory else {
        send(&outbound, &failed(&session_id, NO_CHAT));
        return;
    };
    let claim = match job.operation() {
        Some(operation) => match writes.claim(&directory) {
            Some(claim) => Some(claim),
            None => {
                let busy = AgentGitResult { operation, succeeded: false, message: WRITE_BUSY.to_owned() };
                send(&outbound, &git_result(&session_id, &busy));
                return;
            }
        },
        None => None,
    };
    spawn_local(async move {
        let work = tokio::task::spawn_blocking(move || {
            let _claim = claim;
            let git = ProcessGit::find();
            job.run(git.as_ref().map(|git| git as &dyn GitRunner), &session_id, PathBuf::from(directory))
        });
        // A panic in git's reader threads leaves nothing to send; the phone's spinner then times out on its own.
        if let Ok(events) = work.await {
            for event in events {
                send(&outbound, &event);
            }
        }
    });
}

fn send(outbound: &FrameSender, event: &AgentEvent) {
    // Derived Serialize with string keys only, which cannot fail.
    let payload = serde_json::to_vec(event).expect("agent events always serialise");
    // The connection may have closed meanwhile; there is then nobody to tell.
    let _queued = outbound.send(Frame::new(MessageKind::AgentEvent, payload));
}

fn changes(session_id: &str, report: AgentChangesReport) -> AgentEvent {
    AgentEvent::Changes { session_id: session_id.to_owned(), report: to_value(&report) }
}

fn git_result(session_id: &str, result: &AgentGitResult) -> AgentEvent {
    AgentEvent::GitResult { session_id: session_id.to_owned(), result: to_value(result) }
}

fn failed(session_id: &str, message: &str) -> AgentEvent {
    AgentEvent::Failed { session_id: Some(session_id.to_owned()), message: message.to_owned() }
}

fn to_value(model: &impl serde::Serialize) -> serde_json::Value {
    serde_json::to_value(model).expect("git models have string keys only")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_three_git_requests_become_jobs() {
        let push = AgentRequest::Push { session_id: "s".to_owned() };
        assert!(matches!(GitJob::of(&push), Some((id, GitJob::Push)) if id == "s"));
        assert!(GitJob::of(&AgentRequest::List {}).is_none());
    }

    #[test]
    fn a_folder_takes_one_write_at_a_time() {
        let writes = GitWrites::default();
        let first = writes.claim("C:\\repo");
        assert!(first.is_some());
        assert!(writes.claim("C:\\repo").is_none());
        assert!(writes.claim("C:\\other").is_some());
        drop(first);
        assert!(writes.claim("C:\\repo").is_some());
    }

    #[test]
    fn only_commit_and_push_are_writes() {
        assert_eq!(GitJob::Changes.operation(), None);
        assert_eq!(GitJob::Push.operation(), Some(AgentGitOperation::Push));
    }

    #[test]
    fn without_git_a_review_is_a_failed_report_and_a_commit_a_failed_result() {
        let review = GitJob::Changes.run(None, "s", PathBuf::from("."));
        let [AgentEvent::Changes { report, .. }] = review.as_slice() else { panic!("one report") };
        assert_eq!(report["isRepository"], false);
        let commit = GitJob::Commit { paths: Vec::new(), message: String::new() }.run(None, "s", PathBuf::from("."));
        let [AgentEvent::GitResult { result, .. }, AgentEvent::Changes { .. }] = commit.as_slice() else {
            panic!("a result and a report");
        };
        assert_eq!(result["succeeded"], false);
    }
}
