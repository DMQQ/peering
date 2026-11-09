//! What the routine scheduler needs from this PC: a file for the routines, a look at the disk and `PATH`, and the time zone.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use peering_agent::availability::BinaryLocator;
use peering_agent::routines::{FixedOffset, MemoryRoutineStorage, RoutineEnvironment, RoutineStorage, UtcOffset};

use super::agent::DiskBinaries;

pub struct RoutineServices {
    pub storage: Box<dyn RoutineStorage + Send>,
    pub environment: Box<dyn RoutineEnvironment + Send>,
    pub zone: Box<dyn UtcOffset + Send>,
}

/// A host with nowhere to keep routines and nothing installed: they work until it ends and every run is skipped.
impl Default for RoutineServices {
    fn default() -> Self {
        Self { storage: Box::new(MemoryRoutineStorage::default()), environment: Box::new(NothingInstalled), zone: Box::new(FixedOffset(0)) }
    }
}

impl RoutineServices {
    #[cfg_attr(not(windows), allow(dead_code))]
    pub fn on_disk(file: PathBuf, zone: Box<dyn UtcOffset + Send>) -> Self {
        Self { storage: Box::new(FileRoutineStorage { path: file }), environment: Box::new(DiskRoutineEnvironment), zone }
    }
}

struct NothingInstalled;

impl RoutineEnvironment for NothingInstalled {
    fn agent_installed(&self, _agent_id: &str) -> bool {
        false
    }

    fn folder_exists(&self, _path: &str) -> bool {
        false
    }
}

pub struct DiskRoutineEnvironment;

impl RoutineEnvironment for DiskRoutineEnvironment {
    fn agent_installed(&self, agent_id: &str) -> bool {
        DiskBinaries.is_installed(agent_id)
    }

    fn folder_exists(&self, path: &str) -> bool {
        Path::new(path).is_dir()
    }
}

/// The routines as one file. The write goes to a file beside it that is renamed over it, so a crash halfway leaves the old
/// routines and never half of the new.
pub struct FileRoutineStorage {
    path: PathBuf,
}

impl RoutineStorage for FileRoutineStorage {
    fn load(&self) -> Result<Option<String>, String> {
        match fs::read_to_string(&self.path) {
            Ok(text) => Ok(Some(text)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.to_string()),
        }
    }

    fn save(&self, text: &str) -> Result<(), String> {
        self.write(text).map_err(|error| error.to_string())
    }
}

impl FileRoutineStorage {
    fn write(&self, text: &str) -> io::Result<()> {
        if let Some(folder) = self.path.parent() {
            fs::create_dir_all(folder)?;
        }
        let temporary = self.path.with_extension("json.tmp");
        let written = fs::File::create(&temporary)
            .and_then(|mut file| file.write_all(text.as_bytes()).and_then(|()| file.sync_all()))
            .and_then(|()| fs::rename(&temporary, &self.path));
        if written.is_err() {
            // A temporary file that cannot be removed is overwritten by the next save.
            drop(fs::remove_file(&temporary));
        }
        written
    }
}

/// Seconds east of UTC from what `GetTimeZoneInformation` reports: the bias is minutes WEST, and the daylight or standard
/// bias is added to it while that rule is in force.
#[cfg_attr(not(windows), allow(dead_code))]
fn offset_from_bias(daylight_now: bool, bias: i32, standard_bias: i32, daylight_bias: i32) -> i64 {
    let west = bias + if daylight_now { daylight_bias } else { standard_bias };
    -i64::from(west) * 60
}

/// The zone Windows is set to. It reads today's rule for any moment asked, so a run planned across a clock change lands an
/// hour off until the next check recomputes it.
#[cfg(windows)]
pub struct WindowsZone;

#[cfg(windows)]
impl UtcOffset for WindowsZone {
    fn seconds_east(&self, _unix_seconds: i64) -> i64 {
        use windows::Win32::System::Time::{GetTimeZoneInformation, TIME_ZONE_INFORMATION};
        const TIME_ZONE_ID_DAYLIGHT: u32 = 2;
        let mut info = TIME_ZONE_INFORMATION::default();
        // SAFETY: `info` is a valid, writable TIME_ZONE_INFORMATION for the call to fill.
        let kind = unsafe { GetTimeZoneInformation(&mut info) };
        offset_from_bias(kind == TIME_ZONE_ID_DAYLIGHT, info.Bias, info.StandardBias, info.DaylightBias)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("peering-routines-{name}-{}", std::process::id()));
        drop(fs::remove_dir_all(&path));
        path
    }

    #[test]
    fn a_missing_file_is_no_routines_and_a_saved_one_comes_back() {
        let directory = folder("round");
        let storage = FileRoutineStorage { path: directory.join("routines.json") };
        assert_eq!(storage.load(), Ok(None));
        storage.save("[1]").expect("the folder is writable");
        assert_eq!(storage.load(), Ok(Some("[1]".to_owned())));
        storage.save("[2]").expect("replaces");
        assert_eq!(storage.load(), Ok(Some("[2]".to_owned())));
        assert!(!directory.join("routines.json.tmp").exists(), "the temporary file was renamed away");
        drop(fs::remove_dir_all(directory));
    }

    #[test]
    fn a_path_that_cannot_be_read_is_an_error_and_not_an_empty_list() {
        let directory = folder("unreadable");
        fs::create_dir_all(directory.join("routines.json")).expect("a folder where the file should be");
        let storage = FileRoutineStorage { path: directory.join("routines.json") };
        assert!(storage.load().is_err());
        drop(fs::remove_dir_all(directory));
    }

    #[test]
    fn windows_bias_is_minutes_west_and_the_rule_in_force_is_added() {
        // Central European Time: bias -60, standard 0, daylight -60.
        assert_eq!(offset_from_bias(false, -60, 0, -60), 3600);
        assert_eq!(offset_from_bias(true, -60, 0, -60), 7200);
        // US Pacific: bias 480, standard 0, daylight -60.
        assert_eq!(offset_from_bias(false, 480, 0, -60), -8 * 3600);
        assert_eq!(offset_from_bias(true, 480, 0, -60), -7 * 3600);
    }
}
