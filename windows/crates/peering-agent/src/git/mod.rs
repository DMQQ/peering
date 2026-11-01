//! The review of a chat's folder through git, and the commit and push the phone may ask for. Mirrors
//! `AgentChangesReader.swift` and `AgentGitActions.swift`: every list git is run with comes from `plan`, and the folder
//! is always the chat's own, never one the phone names.

mod diff;
pub mod locator;
mod outcome;
pub mod plan;
pub mod process;
mod report;

#[cfg(test)]
mod tests;

use std::path::Path;
use std::time::Duration;

use peering_wire::agent::{AgentGitOperation, AgentGitResult};

pub use report::{branch, changes_report};

const WRITE_TIMEOUT: Duration = Duration::from_secs(90);
const READ_TIMEOUT: Duration = Duration::from_secs(20);
const WRITE_OUTPUT_LIMIT: usize = 64 * 1024;

pub struct GitRun<'a> {
    pub arguments: &'a [String],
    pub limit: usize,
    pub timeout: Duration,
    /// Reads git's error text too. A commit's hooks and a push's credentials need it.
    pub writes: bool,
}

#[derive(Debug, Clone, Default)]
pub struct GitOutput {
    pub data: Vec<u8>,
    /// The limit was reached and git was stopped.
    pub truncated: bool,
    pub succeeded: bool,
}

impl GitOutput {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.data).into_owned()
    }
}

/// Starts git. `None` when git cannot be started at all.
pub trait GitRunner {
    fn run(&self, run: GitRun<'_>, directory: &Path) -> Option<GitOutput>;
}

pub(crate) fn read(git: &dyn GitRunner, arguments: &[&str], directory: &Path, limit: usize) -> Option<GitOutput> {
    let arguments: Vec<String> = arguments.iter().map(|word| (*word).to_owned()).collect();
    git.run(GitRun { arguments: &arguments, limit, timeout: READ_TIMEOUT, writes: false }, directory)
}

fn write(git: &dyn GitRunner, arguments: &[String], directory: &Path) -> Option<GitOutput> {
    git.run(GitRun { arguments, limit: WRITE_OUTPUT_LIMIT, timeout: WRITE_TIMEOUT, writes: true }, directory)
}

pub fn commit(git: &dyn GitRunner, directory: &Path, paths: &[String], message: &str) -> AgentGitResult {
    let operation = AgentGitOperation::Commit;
    let plan = match plan::commit_plan(paths, message) {
        Ok(plan) => plan,
        Err(reason) => return outcome::refused(operation, &reason),
    };
    if let Some(escaping) = paths.iter().find(|path| !stays_inside(directory, path)) {
        return outcome::refused(operation, &plan::GitRefusal::UnsafePath(escaping.clone()));
    }
    let Some(staged) = write(git, &plan.stage, directory) else {
        return outcome::failure(operation, locator::MISSING_MESSAGE);
    };
    if !staged.succeeded {
        return outcome::result(operation, false, &staged.text());
    }
    let Some(committed) = write(git, &plan.commit, directory) else {
        return outcome::failure(operation, locator::MISSING_MESSAGE);
    };
    outcome::result(operation, committed.succeeded, &committed.text())
}

pub fn push(git: &dyn GitRunner, directory: &Path) -> AgentGitResult {
    let operation = AgentGitOperation::Push;
    let Some(branch) = branch(git, directory) else {
        return outcome::failure(operation, "This folder is not in a git repository.");
    };
    let arguments = match plan::push_arguments(&branch) {
        Ok(arguments) => arguments,
        Err(reason) => return outcome::refused(operation, &reason),
    };
    let Some(output) = write(git, &arguments, directory) else {
        return outcome::failure(operation, locator::MISSING_MESSAGE);
    };
    outcome::result(operation, output.succeeded, &output.text())
}

/// The nearest part of the path still on disk, with links followed, is under the chat's folder, and what is gone
/// below it holds no `..`. The file, or a whole folder of them, may have been deleted.
fn stays_inside(directory: &Path, path: &str) -> bool {
    let Ok(root) = directory.canonicalize() else { return false };
    let joined = directory.join(path);
    let Some((existing, canonical)) =
        joined.ancestors().find_map(|ancestor| ancestor.canonicalize().ok().map(|canonical| (ancestor, canonical)))
    else {
        return false;
    };
    let gone_part_is_plain = joined
        .strip_prefix(existing)
        .is_ok_and(|gone| gone.components().all(|part| matches!(part, std::path::Component::Normal(_))));
    gone_part_is_plain && canonical.starts_with(root)
}
