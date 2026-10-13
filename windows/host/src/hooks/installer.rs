//! Writes Peering's hooks into Claude Code's `settings.json` and the script they call, and takes them out again. Only
//! ever called after the person said yes.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use peering_core::terminal::hooks::settings::{self, UnexpectedShape, COMMAND_NAME};
use serde_json::{Map, Value};

use super::request::{HOOK_PATH, TOKEN_HEADER};

#[derive(Debug, thiserror::Error)]
pub enum InstallError {
    #[error("Claude Code's settings.json is not valid JSON, so Peering left it alone")]
    UnreadableSettings,
    #[error("Claude Code's settings.json has an unexpected \"{0}\", so Peering left it alone")]
    UnexpectedShape(String),
    #[error(transparent)]
    Io(#[from] io::Error),
}

impl From<UnexpectedShape> for InstallError {
    fn from(shape: UnexpectedShape) -> Self {
        Self::UnexpectedShape(shape.0)
    }
}

/// Where the script lives and which settings file it is registered in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookFiles {
    pub settings: PathBuf,
    pub script: PathBuf,
}

impl HookFiles {
    /// `home` is the user's profile folder, `support` the folder Peering keeps its own files in.
    pub fn new(home: &Path, support: &Path) -> Self {
        Self { settings: home.join(".claude").join("settings.json"), script: support.join(format!("{COMMAND_NAME}.cmd")) }
    }

    /// Quoted because the folder may have a space in it, and written with forward slashes because Claude Code runs the
    /// command through a POSIX shell where a backslash escapes.
    pub fn command(&self) -> String {
        format!("\"{}\"", self.script.to_string_lossy().replace('\\', "/"))
    }

    pub fn is_installed(&self) -> bool {
        read_settings(&self.settings).is_ok_and(|current| settings::is_installed(&current))
    }

    pub fn install(&self, port: u16, token: &str) -> Result<(), InstallError> {
        let updated = settings::installing(&self.command(), &read_settings(&self.settings)?)?;
        self.write_script(port, token)?;
        write_settings(&self.settings, &updated)
    }

    pub fn uninstall(&self) -> Result<(), InstallError> {
        let updated = settings::removing(&read_settings(&self.settings)?)?;
        write_settings(&self.settings, &updated)?;
        match fs::remove_file(&self.script) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    /// Rewrites the script for a new port and token, which change on every start of the host.
    pub fn write_script(&self, port: u16, token: &str) -> io::Result<()> {
        if let Some(folder) = self.script.parent() {
            fs::create_dir_all(folder)?;
        }
        fs::write(&self.script, script_text(port, token))
    }
}

/// Silent when Peering is not running: the failed connection prints nothing and the exit is clean, so Claude Code falls
/// back to its own prompt.
pub fn script_text(port: u16, token: &str) -> String {
    format!(
        "@echo off\r\nrem Passes a Claude Code hook to Peering for Windows and prints the answer. Installed by Peering, removed with it.\r\n\
         curl.exe --silent --max-time 620 --data-binary @- --header \"{TOKEN_HEADER}: {token}\" http://127.0.0.1:{port}{HOOK_PATH} 2>nul\r\nexit /b 0\r\n"
    )
}

fn read_settings(path: &Path) -> Result<Map<String, Value>, InstallError> {
    let bytes = match fs::read(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Map::new()),
        other => other?,
    };
    if bytes.iter().all(u8::is_ascii_whitespace) {
        return Ok(Map::new());
    }
    match serde_json::from_slice(&bytes) {
        Ok(Value::Object(settings)) => Ok(settings),
        _ => Err(InstallError::UnreadableSettings),
    }
}

/// Writes through a symlink, so a settings file kept in a dotfiles repo stays a link, and keeps one copy of what was
/// there before the first change. The new text goes to a file beside it that is renamed over it, so a crash halfway
/// leaves the old settings, never half of the new.
fn write_settings(path: &Path, settings: &Map<String, Value>) -> Result<(), InstallError> {
    let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Some(folder) = target.parent() {
        fs::create_dir_all(folder)?;
    }
    let backup = target.with_extension("json.peering-backup");
    if target.exists() && !backup.exists() {
        fs::copy(&target, &backup)?;
    }
    let text = serde_json::to_string_pretty(settings).map_err(io::Error::other)?;
    let temporary = target.with_extension("json.peering-tmp");
    let replaced = write_synced(&temporary, (text + "\n").as_bytes()).and_then(|()| fs::rename(&temporary, &target));
    if replaced.is_err() {
        drop(fs::remove_file(&temporary));
    }
    Ok(replaced?)
}

fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = fs::File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}
