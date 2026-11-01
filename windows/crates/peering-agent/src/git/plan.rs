//! The argument lists for a commit and a push, built only from values that passed the checks here. Mirrors
//! `AgentGitCommit.swift` and `AgentGitPush.swift`: paths follow `--`, the message is the value of `-m`, and a push
//! names an explicit refspec so a configured `remote.<name>.push` (which could carry a `+`) is never consulted.

use peering_wire::agent::{is_inside_folder, AgentGitBranch};

pub const MAXIMUM_FILES: usize = 1_000;
pub const MAXIMUM_MESSAGE_LENGTH: usize = 5_000;

/// Why a request was refused before git was asked anything.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GitRefusal {
    NoFiles,
    TooManyFiles,
    EmptyMessage,
    MessageTooLong,
    UnsafePath(String),
    DetachedHead,
    NoUpstream,
    UnsafeBranch,
    UnsafeRemote,
}

impl GitRefusal {
    pub fn text(&self) -> String {
        match self {
            Self::NoFiles => "Choose at least one file to commit.".to_owned(),
            Self::TooManyFiles => "That is too many files for one commit from the phone.".to_owned(),
            Self::EmptyMessage => "A commit needs a message.".to_owned(),
            Self::MessageTooLong => "That commit message is too long.".to_owned(),
            Self::UnsafePath(path) => format!("{path} is not a file inside this folder."),
            Self::DetachedHead => {
                "This folder is not on a branch (detached HEAD), so there is nothing to push.".to_owned()
            }
            Self::NoUpstream => "This branch has no upstream. Set one on the PC, then push from here.".to_owned(),
            Self::UnsafeBranch => "This branch's name is not one the phone will push.".to_owned(),
            Self::UnsafeRemote => "This branch's remote is not one the phone will push to.".to_owned(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitPlan {
    pub stage: Vec<String>,
    pub commit: Vec<String>,
}

pub fn commit_plan(paths: &[String], message: &str) -> Result<CommitPlan, GitRefusal> {
    let mut unique: Vec<String> = Vec::new();
    for path in paths {
        if !unique.contains(path) {
            unique.push(path.clone());
        }
    }
    if unique.is_empty() {
        return Err(GitRefusal::NoFiles);
    }
    if unique.len() > MAXIMUM_FILES {
        return Err(GitRefusal::TooManyFiles);
    }
    if let Some(bad) = unique.iter().find(|path| !is_committable(path)) {
        return Err(GitRefusal::UnsafePath(bad.clone()));
    }
    let text = message.trim();
    if text.is_empty() {
        return Err(GitRefusal::EmptyMessage);
    }
    if text.chars().count() > MAXIMUM_MESSAGE_LENGTH || text.contains('\0') {
        return Err(GitRefusal::MessageTooLong);
    }
    // Literal, so a name that looks like a pathspec (`:(glob)*`) is a file name and nothing wider.
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    let mut stage = words(&["--literal-pathspecs", "add", "--"]);
    stage.extend(unique.iter().cloned());
    let mut commit = words(&["--literal-pathspecs", "commit", "-m", text, "--"]);
    commit.extend(unique);
    Ok(CommitPlan { stage, commit })
}

/// Inside the folder, and not git's own directory. A backslash is refused because on Windows it is a separator the
/// folder check does not see.
pub fn is_committable(path: &str) -> bool {
    if !is_inside_folder(path) || path.contains('\n') || path.contains('\\') || path.contains(':') {
        return false;
    }
    !path.split('/').any(|part| part.eq_ignore_ascii_case(".git"))
}

/// From `git status --porcelain=v2 --branch`; `remote` and `merge_ref` come from the branch's own config.
pub fn branch(status_headers: &str, remote: Option<&str>, merge_ref: Option<&str>) -> Option<AgentGitBranch> {
    let mut found = AgentGitBranch::default();
    let mut saw_head = false;
    for line in status_headers.lines() {
        let Some(rest) = line.strip_prefix("# branch.") else { continue };
        let Some((key, value)) = rest.split_once(' ') else { continue };
        match key {
            "head" => {
                saw_head = true;
                found.head = (value != "(detached)").then(|| value.to_owned());
            }
            "upstream" => found.upstream = Some(value.to_owned()),
            "ab" => {
                if let Some((ahead, behind)) = value.split_once(' ') {
                    found.ahead = ahead.get(1..).and_then(|count| count.parse().ok()).unwrap_or(0);
                    found.behind = behind.get(1..).and_then(|count| count.parse().ok()).unwrap_or(0);
                }
            }
            _ => {}
        }
    }
    let non_empty = |value: Option<&str>| value.map(str::trim).filter(|value| !value.is_empty()).map(str::to_owned);
    found.remote = non_empty(remote);
    found.merge_ref = non_empty(merge_ref);
    saw_head.then_some(found)
}

pub fn push_arguments(branch: &AgentGitBranch) -> Result<Vec<String>, GitRefusal> {
    let head = branch.head.as_deref().ok_or(GitRefusal::DetachedHead)?;
    let (Some(_), Some(remote), Some(merge_ref)) = (&branch.upstream, &branch.remote, &branch.merge_ref) else {
        return Err(GitRefusal::NoUpstream);
    };
    if !is_plain_ref_name(head) {
        return Err(GitRefusal::UnsafeBranch);
    }
    if !is_plain_remote_name(remote) {
        return Err(GitRefusal::UnsafeRemote);
    }
    if !merge_ref.strip_prefix("refs/heads/").is_some_and(is_plain_ref_name) {
        return Err(GitRefusal::UnsafeBranch);
    }
    Ok(vec![
        "push".to_owned(),
        "--no-follow-tags".to_owned(),
        remote.clone(),
        format!("refs/heads/{head}:{merge_ref}"),
    ])
}

/// Letters, digits and `._-/` only, with none of git's reserved shapes.
fn is_plain_ref_name(name: &str) -> bool {
    if name.is_empty() || name.chars().count() > 200 {
        return false;
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || "._-/".contains(c)) {
        return false;
    }
    !(name.starts_with('-')
        || name.starts_with('/')
        || name.starts_with('.')
        || name.ends_with('/')
        || name.ends_with('.')
        || name.ends_with(".lock")
        || name.contains("..")
        || name.contains("//")
        || name.contains("/."))
}

/// A configured remote's name, never a URL or a path.
fn is_plain_remote_name(name: &str) -> bool {
    is_plain_ref_name(name) && name != "." && !name.contains('/')
}

#[cfg(test)]
mod tests;
