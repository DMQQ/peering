//! Which git the host may start: the first absolute `git.exe` on PATH, then where Git for Windows installs itself.

use std::path::{Path, PathBuf};

pub const MISSING_MESSAGE: &str =
    "git is not installed on this PC. Install Git for Windows from git-scm.com to review changes.";

#[cfg(windows)]
const EXECUTABLE: &str = "git.exe";
#[cfg(not(windows))]
const EXECUTABLE: &str = "git";

/// `variable` reads an environment variable; `exists` says whether a file is there. A relative PATH entry is skipped,
/// so a repository holding its own `git.exe` is never the one started.
pub fn executable(variable: impl Fn(&str) -> Option<String>, exists: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let on_path = variable("PATH")
        .map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .unwrap_or_default()
        .into_iter()
        .filter(|folder| folder.is_absolute())
        .map(|folder| folder.join(EXECUTABLE));
    let installed = [("ProgramFiles", "Git"), ("ProgramW6432", "Git"), ("ProgramFiles(x86)", "Git"), ("LOCALAPPDATA", "Programs\\Git")]
        .into_iter()
        .filter_map(|(name, folder)| variable(name).map(|root| Path::new(&root).join(folder).join("cmd").join(EXECUTABLE)));
    on_path.chain(installed).find(|candidate| candidate.is_absolute() && exists(candidate))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    const ROOT: &str = "C:\\";
    #[cfg(not(windows))]
    const ROOT: &str = "/";

    fn absolute(folder: &str) -> String {
        format!("{ROOT}{folder}")
    }

    #[test]
    fn the_first_absolute_path_entry_holding_git_wins() {
        let path = std::env::join_paths(["relative", &absolute("empty"), &absolute("tools")]).expect("joins");
        let path = path.to_string_lossy().into_owned();
        let found = executable(
            |name| (name == "PATH").then(|| path.clone()),
            |candidate| !candidate.starts_with(absolute("empty")),
        );
        assert_eq!(found, Some(Path::new(&absolute("tools")).join(EXECUTABLE)));
    }

    #[test]
    fn without_git_on_path_the_installed_copy_is_found() {
        let program_files = absolute("Program Files");
        let expected = Path::new(&program_files).join("Git").join("cmd").join(EXECUTABLE);
        let found = executable(
            |name| (name == "ProgramFiles").then(|| program_files.clone()),
            |candidate| candidate == expected,
        );
        assert_eq!(found, Some(expected.clone()));
        assert_eq!(executable(|_| None, |_| true), None);
    }
}
