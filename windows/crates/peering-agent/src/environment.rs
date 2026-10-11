//! Finds the agent CLIs on Windows and says how to start each one. Mirrors `apple/MacCastHost/Agent/Process/AgentEnvironment.swift`.

#[cfg(test)]
mod tests;

const DEFAULT_PATH_EXTENSIONS: [&str; 4] = [".COM", ".EXE", ".BAT", ".CMD"];

/// The filesystem question the search asks. Real code answers it from the disk; tests answer it from a set.
pub trait Exists {
    fn exists(&self, path: &str) -> bool;
}

/// Where a binary may be, in the order it is looked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchEnv {
    path_entries: Vec<String>,
    path_extensions: Vec<String>,
    extra_directories: Vec<String>,
}

impl SearchEnv {
    /// `path` and `path_ext` are the raw `PATH` and `PATHEXT` values. An unset `PATHEXT` falls back to the
    /// Windows default. The extra directories are the per-user install locations agent CLIs use.
    pub fn new(path: &str, path_ext: Option<&str>, user_profile: &str, app_data: Option<&str>) -> Self {
        let path_extensions = path_ext
            .map(split_list)
            .filter(|extensions| !extensions.is_empty())
            .unwrap_or_else(|| DEFAULT_PATH_EXTENSIONS.iter().map(|extension| (*extension).to_owned()).collect());
        let mut extra_directories = vec![
            format!("{user_profile}\\.local\\bin"),
            format!("{user_profile}\\.claude\\local"),
        ];
        if let Some(app_data) = app_data {
            extra_directories.insert(1, format!("{app_data}\\npm"));
        }
        Self {
            path_entries: split_list(path),
            path_extensions,
            extra_directories,
        }
    }

    fn directories(&self) -> impl Iterator<Item = &str> {
        self.path_entries.iter().chain(&self.extra_directories).map(String::as_str)
    }
}

/// A binary found on disk. `needs_cmd_wrapper` is true for a `.cmd` or `.bat` shim, which CreateProcess cannot
/// run directly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub path: String,
    pub needs_cmd_wrapper: bool,
}

/// The first file named `name` plus a `PATHEXT` extension, looking through `PATH` entries in order (each with
/// every extension in `PATHEXT` order) and then the extra directories. `None` for an invalid name or a miss.
pub fn find_binary(name: &str, search: &SearchEnv, fs: &dyn Exists) -> Option<Resolved> {
    if !is_valid_binary_name(name) {
        return None;
    }
    search.directories().find_map(|directory| {
        search.path_extensions.iter().find_map(|extension| {
            let path = format!("{directory}\\{name}{extension}");
            fs.exists(&path).then(|| Resolved {
                needs_cmd_wrapper: is_cmd_shim(extension),
                path,
            })
        })
    })
}

/// The program and arguments that start a found binary with `args`.
pub fn launch_command(resolved: &Resolved, args: &[String]) -> (String, Vec<String>) {
    if resolved.needs_cmd_wrapper {
        let mut full = vec!["/c".to_owned(), resolved.path.clone()];
        full.extend_from_slice(args);
        ("cmd.exe".to_owned(), full)
    } else {
        (resolved.path.clone(), args.to_vec())
    }
}

/// Letters, digits, `-` and `_` only, as the Mac host accepts, so a name cannot carry a path or an extension.
pub fn is_valid_binary_name(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|character| character.is_alphanumeric() || character == '-' || character == '_')
}

fn is_cmd_shim(extension: &str) -> bool {
    matches!(extension.to_ascii_lowercase().as_str(), ".cmd" | ".bat")
}

fn split_list(value: &str) -> Vec<String> {
    value
        .split(';')
        .map(|entry| entry.trim().trim_matches('"'))
        .filter(|entry| !entry.is_empty())
        .map(str::to_owned)
        .collect()
}
