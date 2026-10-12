//! Where shells are looked for and where a new one starts, from the environment variables Windows sets.

use std::path::Path;

use peering_core::terminal::shell::{discover, Shell, ShellSearch};

/// `get` reads one environment variable.
pub fn shell_search(get: &dyn Fn(&str) -> Option<String>) -> ShellSearch {
    let path = get("PATH").unwrap_or_default();
    ShellSearch {
        path_entries: path.split(';').filter(|entry| !entry.is_empty()).map(str::to_owned).collect(),
        program_files: get("ProgramFiles"),
        system_root: get("SystemRoot"),
        command_interpreter: get("ComSpec"),
    }
}

/// The shells installed on this PC, newest PowerShell first.
pub fn installed_shells(get: &dyn Fn(&str) -> Option<String>) -> Vec<Shell> {
    discover(&shell_search(get), &|path| Path::new(path).is_file())
}

/// Where a new terminal starts: the user's profile folder, else the current directory.
pub fn start_directory(get: &dyn Fn(&str) -> Option<String>) -> String {
    get("USERPROFILE")
        .filter(|profile| !profile.is_empty())
        .or_else(|| std::env::current_dir().ok().map(|directory| directory.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "C:\\".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn variables(name: &str) -> Option<String> {
        match name {
            "PATH" => Some("C:\\Tools;;C:\\Windows".to_owned()),
            "ProgramFiles" => Some("C:\\Program Files".to_owned()),
            "SystemRoot" => Some("C:\\Windows".to_owned()),
            "ComSpec" => Some("C:\\Windows\\System32\\cmd.exe".to_owned()),
            "USERPROFILE" => Some("C:\\Users\\me".to_owned()),
            _ => None,
        }
    }

    #[test]
    fn the_search_reads_path_entries_and_the_windows_folders() {
        let search = shell_search(&variables);
        assert_eq!(search.path_entries, ["C:\\Tools", "C:\\Windows"]);
        assert_eq!(search.program_files.as_deref(), Some("C:\\Program Files"));
        assert_eq!(search.system_root.as_deref(), Some("C:\\Windows"));
        assert_eq!(search.command_interpreter.as_deref(), Some("C:\\Windows\\System32\\cmd.exe"));
    }

    #[test]
    fn a_new_terminal_starts_in_the_user_profile() {
        assert_eq!(start_directory(&variables), "C:\\Users\\me");
    }

    #[test]
    fn without_a_profile_the_start_directory_is_still_a_folder() {
        assert!(!start_directory(&|_| None).is_empty());
    }
}
