//! `settings.txt` in the host's data folder: read at start, rewritten whole when a setting changes. The write goes to a file
//! beside it that is renamed over it, so a crash halfway leaves the old settings and never half of the new.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use peering_core::settings::HostSettings;

const FILE_NAME: &str = "settings.txt";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsStore {
    path: PathBuf,
}

/// What `load` found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Loaded {
    pub settings: HostSettings,
    /// Why the stored settings were not used, when they could not be read. The defaults stand in.
    pub problem: Option<String>,
}

impl SettingsStore {
    pub fn in_directory(directory: &Path) -> Self {
        Self { path: directory.join(FILE_NAME) }
    }

    /// The stored settings, validated. A missing file is the first run and no problem; a file that cannot be read is a problem
    /// and the defaults are used, so the host still starts.
    pub fn load(&self, default_device_name: &str) -> Loaded {
        match fs::read_to_string(&self.path) {
            Ok(text) => Loaded { settings: HostSettings::from_text(&text, default_device_name).validated(), problem: None },
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                Loaded { settings: HostSettings::default_for(default_device_name), problem: None }
            }
            Err(error) => Loaded {
                settings: HostSettings::default_for(default_device_name),
                problem: Some(format!("The saved settings could not be read ({error}), so the defaults are in use.")),
            },
        }
    }

    pub fn save(&self, settings: &HostSettings) -> io::Result<()> {
        if let Some(folder) = self.path.parent() {
            fs::create_dir_all(folder)?;
        }
        let temporary = self.path.with_extension("txt.tmp");
        let written = write_synced(&temporary, settings.to_text().as_bytes()).and_then(|()| fs::rename(&temporary, &self.path));
        if written.is_err() {
            // A temporary file that cannot be removed is overwritten by the next save.
            drop(fs::remove_file(&temporary));
        }
        written
    }
}

fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = fs::File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("peering-settings-{name}-{}", std::process::id()));
        drop(fs::remove_dir_all(&path));
        path
    }

    #[test]
    fn a_first_run_has_no_file_and_gets_the_defaults_without_a_problem() {
        let store = SettingsStore::in_directory(&folder("first"));
        let loaded = store.load("Office PC");
        assert_eq!(loaded.settings, HostSettings::default_for("Office PC"));
        assert_eq!(loaded.problem, None);
    }

    #[test]
    fn saved_settings_come_back() {
        let directory = folder("round");
        let store = SettingsStore::in_directory(&directory);
        let settings = HostSettings { port: 40000, frame_rate: 30, relay_enabled: false, terminal_hooks: true, ..HostSettings::default_for("Den") };
        store.save(&settings).expect("the folder is writable");
        assert_eq!(store.load("ignored").settings, settings);
        drop(fs::remove_dir_all(directory));
    }

    #[test]
    fn a_saved_value_out_of_range_is_brought_back_into_range() {
        let directory = folder("range");
        fs::create_dir_all(&directory).expect("the folder is writable");
        fs::write(directory.join(FILE_NAME), "frameRate=45\nport=0\n").expect("the file is writable");
        let loaded = SettingsStore::in_directory(&directory).load("PC");
        assert_eq!((loaded.settings.frame_rate, loaded.settings.port), (60, 51515));
        drop(fs::remove_dir_all(directory));
    }

    #[test]
    fn a_file_that_cannot_be_read_gives_the_defaults_and_says_so() {
        let directory = folder("unreadable");
        fs::create_dir_all(directory.join(FILE_NAME)).expect("a folder where the file should be");
        let loaded = SettingsStore::in_directory(&directory).load("PC");
        assert_eq!(loaded.settings, HostSettings::default_for("PC"));
        assert!(loaded.problem.is_some());
        drop(fs::remove_dir_all(directory));
    }

    #[test]
    fn a_save_that_cannot_happen_is_an_error() {
        let directory = folder("blocked");
        fs::create_dir_all(&directory).expect("the folder is writable");
        let blocker = directory.join("not-a-folder");
        fs::write(&blocker, b"x").expect("the file is writable");
        let store = SettingsStore::in_directory(&blocker);
        assert!(store.save(&HostSettings::default_for("PC")).is_err());
        drop(fs::remove_dir_all(directory));
    }
}
