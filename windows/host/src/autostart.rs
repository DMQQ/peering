//! Start at login: the per-user Run key that starts the host when its user signs in. The builder is pure and tested
//! natively. The executors (Windows only) run `reg.exe`; they are unverified until run on Windows.

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

#[cfg(windows)]
pub fn write_run_key(exe_path: &Path) -> std::io::Result<()> {
    let value = run_key_command(exe_path).map_err(|error| std::io::Error::other(error.to_string()))?;
    let status = std::process::Command::new("reg")
        .args(["add", value.key, "/v", value.name, "/t", "REG_SZ", "/d", &value.data, "/f"])
        .status()?;
    status.success().then_some(()).ok_or_else(|| std::io::Error::other("reg could not write the Run entry"))
}

#[cfg(windows)]
pub fn remove_run_key() -> std::io::Result<()> {
    // reg reports a missing entry as a failure, and a missing entry is the outcome asked for, so its exit status is not read.
    let _removed_or_absent = std::process::Command::new("reg").args(["delete", RUN_KEY, "/v", VALUE_NAME, "/f"]).status()?;
    Ok(())
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
}
