//! Which shells this PC has, how each is started, and the environment they get.

mod hook;

pub use hook::POWERSHELL_FINISH_HOOK;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellKind {
    PowerShell,
    Cmd,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shell {
    pub kind: ShellKind,
    pub program: String,
    pub arguments: Vec<String>,
}

/// Where the shells may be, as the environment names them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ShellSearch {
    pub path_entries: Vec<String>,
    pub program_files: Option<String>,
    pub system_root: Option<String>,
    pub command_interpreter: Option<String>,
}

/// The installed shells in the order they are offered: PowerShell 7, Windows PowerShell, then cmd.
pub fn discover(search: &ShellSearch, exists: &dyn Fn(&str) -> bool) -> Vec<Shell> {
    let mut shells = Vec::new();
    let pwsh = search
        .path_entries
        .iter()
        .map(|entry| join(entry, "pwsh.exe"))
        .chain(search.program_files.iter().map(|root| join(root, "PowerShell\\7\\pwsh.exe")))
        .find(|candidate| exists(candidate));
    shells.extend(pwsh.map(powershell));
    let system32 = |name: &str| search.system_root.as_ref().map(|root| join(root, &format!("System32\\{name}")));
    let windows_powershell = system32("WindowsPowerShell\\v1.0\\powershell.exe").filter(|path| exists(path));
    shells.extend(windows_powershell.map(powershell));
    let cmd = search.command_interpreter.clone().into_iter().chain(system32("cmd.exe")).find(|path| exists(path));
    shells.extend(cmd.map(|program| Shell { kind: ShellKind::Cmd, program, arguments: Vec::new() }));
    shells
}

fn powershell(program: String) -> Shell {
    let arguments = ["-NoLogo", "-NoExit", "-Command", POWERSHELL_FINISH_HOOK].map(str::to_owned).to_vec();
    Shell { kind: ShellKind::PowerShell, program, arguments }
}

fn join(directory: &str, name: &str) -> String {
    format!("{}\\{name}", directory.trim_end_matches('\\'))
}

/// The user's environment with the variables a phone-drawn terminal needs. A program that repaints cell by cell is
/// every weakness of replaying bytes onto a grid, and a full-screen program on the alternate screen is that, so
/// Claude Code is told not to use it.
pub fn terminal_environment(user: impl IntoIterator<Item = (String, String)>) -> Vec<(String, String)> {
    const FIXED: [(&str, &str); 3] =
        [("TERM", "xterm-256color"), ("COLORTERM", "truecolor"), ("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN", "1")];
    let mut environment: Vec<(String, String)> = user
        .into_iter()
        .filter(|(name, _)| !FIXED.iter().any(|(fixed, _)| fixed.eq_ignore_ascii_case(name)))
        .collect();
    environment.extend(FIXED.map(|(name, value)| (name.to_owned(), value.to_owned())));
    environment
}

#[cfg(test)]
mod tests;
