//! Start at login: the per-user Run key that starts the host when its user signs in. The builder is pure and tested
//! natively. The executors (Windows only) run `%SystemRoot%\\System32\\reg.exe` with a deadline and are unverified until run on Windows.

use std::path::Path;

pub const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
pub const VALUE_NAME: &str = "Peering Host";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryValue {
    pub key: &'static str,
    pub name: &'static str,
    pub data: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AutostartError {
    #[error("the program path is not valid Unicode")]
    NotUnicode,
    #[error("the program path contains a double quote, which Windows paths cannot hold")]
    Quote,
}

/// The Run entry for the executable at `exe_path`. The path is quoted, so a path with spaces starts the right program.
pub fn run_key_command(exe_path: &Path) -> Result<RegistryValue, AutostartError> {
    let path = exe_path.to_str().ok_or(AutostartError::NotUnicode)?;
    if path.contains('"') {
        return Err(AutostartError::Quote);
    }
    Ok(RegistryValue { key: RUN_KEY, name: VALUE_NAME, data: format!("\"{path}\"") })
}

/// The `reg` arguments that write `value`.
pub fn reg_add_args(value: &RegistryValue) -> Vec<String> {
    ["add", value.key, "/v", value.name, "/t", "REG_SZ", "/d", &value.data, "/f"].iter().map(ToString::to_string).collect()
}

pub fn reg_delete_args() -> Vec<String> {
    ["delete", RUN_KEY, "/v", VALUE_NAME, "/f"].iter().map(ToString::to_string).collect()
}

pub fn reg_query_args() -> Vec<String> {
    ["query", RUN_KEY, "/v", VALUE_NAME].iter().map(ToString::to_string).collect()
}

#[cfg(windows)]
const REG_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

#[cfg(windows)]
fn reg(arguments: &[String]) -> crate::tools::ToolOutcome {
    crate::tools::run(&crate::tools::system_tool("reg"), arguments, REG_TIMEOUT)
}

/// Blocks for as long as `reg` takes, up to its timeout: call it from a worker thread.
#[cfg(windows)]
pub fn write_run_key(exe_path: &Path) -> std::io::Result<()> {
    let value = run_key_command(exe_path).map_err(|error| std::io::Error::other(error.to_string()))?;
    let outcome = reg(&reg_add_args(&value));
    outcome.succeeded().then_some(()).ok_or_else(|| std::io::Error::other(format!("reg could not write the Run entry: {}", outcome.describe())))
}

/// What the lookup of the Run entry says about removing it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Removal {
    /// The entry is there and has to be deleted.
    Delete,
    /// `reg` reported the entry missing, which is the outcome asked for.
    AlreadyAbsent,
    /// `reg` did not answer (it timed out, did not start or failed another way), so nothing is known about the entry.
    Unknown(String),
}

/// `reg query` exits 1 for a missing value. Any other failure leaves the entry's state unknown, and removing must not
/// claim success for an entry that may still be there.
pub fn removal_after_query(query: &crate::tools::ToolOutcome) -> Removal {
    use crate::tools::ToolOutcome;
    match query {
        ToolOutcome::Succeeded => Removal::Delete,
        ToolOutcome::Failed(Some(1)) => Removal::AlreadyAbsent,
        other => Removal::Unknown(other.describe()),
    }
}

/// `reg delete` fails for a missing entry and for a real error alike, so the entry is looked up first: absent is the
/// outcome asked for, and a lookup that gave no answer is an error rather than a success.
#[cfg(windows)]
pub fn remove_run_key() -> std::io::Result<()> {
    match removal_after_query(&reg(&reg_query_args())) {
        Removal::AlreadyAbsent => return Ok(()),
        Removal::Unknown(reason) => {
            return Err(std::io::Error::other(format!("reg could not tell whether the Run entry exists: {reason}")));
        }
        Removal::Delete => {}
    }
    let outcome = reg(&reg_delete_args());
    outcome.succeeded().then_some(()).ok_or_else(|| std::io::Error::other(format!("reg could not remove the Run entry: {}", outcome.describe())))
}

/// Whether the Run entry exists. A `reg` that fails to run or time out is read as not set, which is what the box should show.
#[cfg(windows)]
pub fn is_enabled() -> bool {
    reg(&reg_query_args()).succeeded()
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn the_run_entry_is_the_quoted_executable_under_the_user_run_key() {
        let value = run_key_command(&PathBuf::from(r"C:\Peering\peering-host.exe")).expect("a plain path builds");
        assert_eq!(value.key, r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run");
        assert_eq!(value.name, "Peering Host");
        assert_eq!(value.data, r#""C:\Peering\peering-host.exe""#);
    }

    #[test]
    fn a_path_with_spaces_stays_one_quoted_program_name() {
        let value = run_key_command(&PathBuf::from(r"C:\Users\Ann\AppData\Local\Programs\Peering Host\peering-host.exe"))
            .expect("a path with spaces builds");
        assert_eq!(value.data, r#""C:\Users\Ann\AppData\Local\Programs\Peering Host\peering-host.exe""#);
    }

    #[test]
    fn a_path_with_a_double_quote_is_refused() {
        let result = run_key_command(&PathBuf::from(r#"C:\Bad"Name\peering-host.exe"#));
        assert_eq!(result, Err(AutostartError::Quote));
    }

    #[test]
    fn a_found_entry_is_deleted_and_a_missing_one_is_already_gone() {
        use crate::tools::ToolOutcome;
        assert_eq!(removal_after_query(&ToolOutcome::Succeeded), Removal::Delete);
        assert_eq!(removal_after_query(&ToolOutcome::Failed(Some(1))), Removal::AlreadyAbsent);
    }

    #[test]
    fn a_lookup_that_timed_out_or_failed_otherwise_does_not_count_as_absent() {
        use crate::tools::ToolOutcome;
        for outcome in [ToolOutcome::TimedOut, ToolOutcome::Failed(Some(5)), ToolOutcome::Failed(None), ToolOutcome::NotStarted("x".to_owned())] {
            assert!(matches!(removal_after_query(&outcome), Removal::Unknown(_)), "{outcome:?}");
        }
    }

    #[test]
    fn the_reg_arguments_name_the_run_key_and_the_value() {
        let value = run_key_command(&PathBuf::from(r"C:\Peering\peering-host.exe")).expect("builds");
        let add = reg_add_args(&value);
        assert_eq!(add[..4], ["add", RUN_KEY, "/v", "Peering Host"]);
        assert_eq!(add[add.len() - 3..], ["/d", r#""C:\Peering\peering-host.exe""#, "/f"]);
        assert_eq!(reg_delete_args(), ["delete", RUN_KEY, "/v", "Peering Host", "/f"]);
        assert_eq!(reg_query_args(), ["query", RUN_KEY, "/v", "Peering Host"]);
    }
}
