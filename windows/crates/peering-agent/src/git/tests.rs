//! Runs the real git in a scratch repository where one is installed, and a missing git through a fake.

use std::fs;
use std::path::{Path, PathBuf};

use peering_wire::agent::{AgentChangeKind, AgentGitOperation};

use super::process::ProcessGit;
use super::*;

struct NoGit;

impl GitRunner for NoGit {
    fn run(&self, _run: GitRun<'_>, _directory: &Path) -> Option<GitOutput> {
        None
    }
}

struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        // A leftover folder under the temp directory harms nothing.
        let _removed = fs::remove_dir_all(&self.0);
    }
}

fn scratch(name: &str) -> Scratch {
    let folder = std::env::temp_dir().join(format!("peering-git-{}-{name}", std::process::id()));
    let _stale = fs::remove_dir_all(&folder);
    fs::create_dir_all(&folder).expect("a scratch folder");
    Scratch(folder)
}

fn git_in(git: &ProcessGit, folder: &Path, arguments: &[&str]) {
    let arguments: Vec<String> = arguments.iter().map(|word| (*word).to_owned()).collect();
    let output = git.run(GitRun { arguments: &arguments, limit: 1 << 20, timeout: WRITE_TIMEOUT, writes: true }, folder);
    assert!(output.is_some_and(|output| output.succeeded), "git {arguments:?}");
}

/// A repository with one commit, an edited file and a new one. `None` where git is not installed.
fn repository(name: &str) -> Option<(ProcessGit, Scratch)> {
    let git = ProcessGit::find()?;
    let folder = scratch(name);
    let path = folder.0.as_path();
    git_in(&git, path, &["init", "-q", "-b", "main"]);
    git_in(&git, path, &["config", "user.email", "test@example.invalid"]);
    git_in(&git, path, &["config", "user.name", "Test"]);
    git_in(&git, path, &["config", "commit.gpgsign", "false"]);
    fs::write(path.join("kept.txt"), "one\n").expect("writes");
    git_in(&git, path, &["add", "kept.txt"]);
    git_in(&git, path, &["commit", "-q", "-m", "first"]);
    fs::write(path.join("kept.txt"), "two\n").expect("writes");
    fs::write(path.join("new.txt"), "hello\n").expect("writes");
    Some((git, folder))
}

#[test]
fn without_git_the_report_and_actions_say_how_to_install_it() {
    let folder = Path::new(".");
    assert_eq!(changes_report(&NoGit, folder).message.as_deref(), Some(locator::MISSING_MESSAGE));
    assert_eq!(commit(&NoGit, folder, &["Cargo.toml".to_owned()], "m").message, locator::MISSING_MESSAGE);
    assert_eq!(push(&NoGit, folder).message, "This folder is not in a git repository.");
}

#[test]
fn a_refused_commit_never_starts_git() {
    let result = commit(&NoGit, Path::new("."), &["../outside".to_owned()], "m");
    assert_eq!(result.message, "../outside is not a file inside this folder.");
    assert_eq!(result.operation, AgentGitOperation::Commit);
}

#[test]
fn a_repository_reports_its_edited_and_new_files_and_branch() {
    let Some((git, folder)) = repository("report") else { return };
    let report = changes_report(&git, &folder.0);
    assert!(report.is_repository);
    let files: Vec<_> = report.files.iter().map(|file| (file.path.as_str(), file.kind, file.added, file.removed)).collect();
    assert_eq!(files, [("kept.txt", AgentChangeKind::Modified, 1, 1), ("new.txt", AgentChangeKind::Untracked, 1, 0)]);
    assert_eq!(report.paths, ["kept.txt", "new.txt"]);
    let branch = report.branch.expect("a branch");
    assert_eq!(branch.head.as_deref(), Some("main"));
    assert_eq!(branch.upstream, None);
}

#[test]
fn a_commit_takes_only_the_chosen_files_and_a_push_without_upstream_is_refused() {
    let Some((git, folder)) = repository("commit") else { return };
    let result = commit(&git, &folder.0, &["new.txt".to_owned()], "Add new.txt");
    assert!(result.succeeded, "{}", result.message);
    let after = changes_report(&git, &folder.0);
    assert_eq!(after.files.iter().map(|file| file.path.as_str()).collect::<Vec<_>>(), ["kept.txt"]);
    assert_eq!(push(&git, &folder.0).message, plan::GitRefusal::NoUpstream.text());
}

#[test]
fn a_folder_outside_any_repository_is_reported_as_such() {
    let Some(git) = ProcessGit::find() else { return };
    let folder = scratch("plain");
    fs::write(folder.0.join(".git"), "not a repository").expect("writes");
    let report = changes_report(&git, &folder.0);
    assert!(!report.is_repository);
}

#[test]
fn a_file_in_a_deleted_folder_counts_as_inside() {
    let folder = scratch("deleted");
    assert!(stays_inside(&folder.0, "gone/deeper/file.txt"));
    assert!(!stays_inside(&folder.0, "gone/../../outside.txt"));
    assert!(!stays_inside(&folder.0, "../outside.txt"));
}

#[test]
fn a_whole_deleted_folder_can_be_committed() {
    let Some((git, folder)) = repository("folder") else { return };
    let path = folder.0.as_path();
    fs::create_dir_all(path.join("old/inner")).expect("creates");
    fs::write(path.join("old/inner/a.txt"), "a\n").expect("writes");
    git_in(&git, path, &["add", "old"]);
    git_in(&git, path, &["commit", "-q", "-m", "old"]);
    fs::remove_dir_all(path.join("old")).expect("removes");
    let result = commit(&git, path, &["old/inner/a.txt".to_owned()], "Remove old");
    assert!(result.succeeded, "{}", result.message);
}
