//! The chat's folder as git sees it. What git prints is checked on the way out: a path that is not relative to the
//! folder, or that resolves outside it through a link, is dropped.

use std::fs::File;
use std::io::Read;
use std::path::Path;

use peering_wire::agent::{is_inside_folder, AgentChangesReport, AgentGitBranch};

use super::{diff, locator, plan, read, GitOutput, GitRunner};

pub const MAXIMUM_PATHS: usize = 5_000;
pub const MAXIMUM_CHANGED_FILES: usize = 300;
pub const MAXIMUM_UNTRACKED_FILES: usize = 100;
const MAXIMUM_UNTRACKED_BYTES: u64 = 200 * 1024;
const PATCH_LIMIT: usize = 4 * 1024 * 1024;
const NAMES_LIMIT: usize = 2 * 1024 * 1024;
const NOT_A_REPOSITORY: &str = "This folder is not in a git repository, so only the agent's own edits are listed.";

pub fn changes_report(git: &dyn GitRunner, directory: &Path) -> AgentChangesReport {
    let Some(probe) = read(git, &["rev-parse", "--is-inside-work-tree"], directory, 64) else {
        return AgentChangesReport::failure(locator::MISSING_MESSAGE);
    };
    if !probe.succeeded || !probe.text().starts_with("true") {
        return AgentChangesReport::failure(NOT_A_REPOSITORY);
    }
    let (tracked, tracked_cut) = names(git, &["ls-files", "-z", "--cached"], directory);
    let (untracked, untracked_cut) = names(git, &["ls-files", "-z", "--others", "--exclude-standard"], directory);
    let patch = tracked_patch(git, directory);

    let mut files: Vec<_> =
        diff::files(&patch.text(), diff::PER_FILE_LIMIT).into_iter().filter(|file| is_inside_folder(&file.path)).collect();
    let mut truncated = patch.truncated || tracked_cut || untracked_cut || files.len() > MAXIMUM_CHANGED_FILES;
    files.truncate(MAXIMUM_CHANGED_FILES);
    let new_files = untracked.iter().take(MAXIMUM_UNTRACKED_FILES).map(|path| {
        let content = text_of(directory, path);
        diff::untracked(path, content.as_deref(), diff::PER_FILE_LIMIT)
    });
    files.extend(new_files);
    truncated |= untracked.len() > MAXIMUM_UNTRACKED_FILES;
    files.sort_by(|left, right| natural_order(&left.path, &right.path));

    let mut paths: Vec<String> = Vec::new();
    for path in tracked.into_iter().chain(untracked) {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    if paths.len() > MAXIMUM_PATHS {
        paths.truncate(MAXIMUM_PATHS);
        truncated = true;
    }
    AgentChangesReport { is_repository: true, files, paths, truncated, message: None, branch: branch(git, directory) }
}

pub fn branch(git: &dyn GitRunner, directory: &Path) -> Option<AgentGitBranch> {
    let status = read(git, &["status", "--porcelain=v2", "--branch", "--untracked-files=no"], directory, 64 * 1024)?;
    if !status.succeeded {
        return None;
    }
    let text = status.text();
    let parsed = plan::branch(&text, None, None)?;
    let Some(head) = parsed.head else { return Some(parsed) };
    let remote = configured(git, &format!("branch.{head}.remote"), directory);
    let merge_ref = configured(git, &format!("branch.{head}.merge"), directory);
    plan::branch(&text, remote.as_deref(), merge_ref.as_deref())
}

fn configured(git: &dyn GitRunner, key: &str, directory: &Path) -> Option<String> {
    let output = read(git, &["config", "--get", key], directory, 1024)?;
    output.succeeded.then(|| output.text().trim().to_owned())
}

/// Against the last commit, so staged and unstaged edits both show; a repository with no commit yet shows what is staged.
fn tracked_patch(git: &dyn GitRunner, directory: &Path) -> GitOutput {
    const OPTIONS: [&str; 6] = ["--relative", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "-U3"];
    let with = |first: [&'static str; 2]| -> Vec<&'static str> { [&first[..], &OPTIONS[..]].concat() };
    if let Some(head) = read(git, &with(["diff", "HEAD"]), directory, PATCH_LIMIT).filter(|output| output.succeeded) {
        return head;
    }
    read(git, &with(["diff", "--cached"]), directory, PATCH_LIMIT).unwrap_or_default()
}

fn names(git: &dyn GitRunner, arguments: &[&str], directory: &Path) -> (Vec<String>, bool) {
    let Some(output) = read(git, arguments, directory, NAMES_LIMIT).filter(|output| output.succeeded) else {
        return (Vec::new(), false);
    };
    let mut parts: Vec<String> =
        output.text().split('\0').filter(|part| is_inside_folder(part)).map(str::to_owned).collect();
    // A cut list ends mid-name.
    if output.truncated {
        parts.pop();
    }
    (parts, output.truncated)
}

/// `None` for a file that is binary, unreadable, or that a link points out of the folder.
fn text_of(directory: &Path, path: &str) -> Option<String> {
    let root = directory.canonicalize().ok()?;
    let file = directory.join(path).canonicalize().ok()?;
    if !file.starts_with(&root) || !file.is_file() {
        return None;
    }
    let mut data = Vec::new();
    File::open(&file).ok()?.take(MAXIMUM_UNTRACKED_BYTES).read_to_end(&mut data).ok()?;
    (!data.contains(&0)).then(|| String::from_utf8_lossy(&data).into_owned())
}

/// Case-insensitive, with runs of digits compared by value, as Finder's `localizedStandardCompare` orders names.
fn natural_order(left: &str, right: &str) -> std::cmp::Ordering {
    let key = |text: &str| -> Vec<(u8, String, u128)> {
        let mut parts = Vec::new();
        let mut chars = text.chars().peekable();
        while let Some(&first) = chars.peek() {
            let digits = first.is_ascii_digit();
            let mut run = String::new();
            while let Some(&next) = chars.peek().filter(|next| next.is_ascii_digit() == digits) {
                run.push(next);
                chars.next();
            }
            let value = if digits { run.parse().unwrap_or(u128::MAX) } else { 0 };
            parts.push((u8::from(!digits), if digits { String::new() } else { run.to_lowercase() }, value));
        }
        parts
    };
    key(left).cmp(&key(right)).then_with(|| left.cmp(right))
}

#[cfg(test)]
mod tests {
    use super::natural_order;

    #[test]
    fn names_sort_without_case_and_with_numbers_by_value() {
        let mut names = vec!["b.txt", "File10.txt", "a.txt", "file2.txt"];
        names.sort_by(|left, right| natural_order(left, right));
        assert_eq!(names, ["a.txt", "b.txt", "file2.txt", "File10.txt"]);
    }
}
