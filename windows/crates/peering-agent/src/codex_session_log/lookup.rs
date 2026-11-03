//! Where a thread's log is. Codex files it under the local date the thread began, so a live thread is in one of the
//! last few day folders; the whole tree is walked once per thread at most, for a thread resumed from long ago.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// A log that is not there yet is looked for again after this long, not on every turn.
const MISS_RETRY: Duration = Duration::from_secs(60);
const SECONDS_PER_DAY: i64 = 86_400;

#[derive(Debug, Default)]
pub struct LogLookup {
    path: Option<PathBuf>,
    missed_at: Option<Instant>,
    walked: bool,
}

impl LogLookup {
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    pub(super) fn find(&mut self, sessions: &Path, thread: &str) -> Option<&Path> {
        if self.path.is_none() && self.missed_at.is_none_or(|missed| missed.elapsed() >= MISS_RETRY) {
            let suffix = format!("{thread}.jsonl");
            let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs() as i64);
            self.path = recent_day_folders(now)
                .iter()
                .find_map(|day| newest_match(&sessions.join(day), &suffix));
            if self.path.is_none() && !self.walked {
                self.walked = true;
                self.path = walk(sessions, &suffix);
            }
            self.missed_at = self.path.is_none().then(Instant::now);
        }
        self.path.as_deref()
    }
}

/// `YYYY/MM/DD` for the UTC days from two before to one after `now`, which hold today's and yesterday's local date
/// in every time zone.
pub fn recent_day_folders(now_unix: i64) -> Vec<PathBuf> {
    let today = now_unix.div_euclid(SECONDS_PER_DAY);
    [today, today - 1, today + 1, today - 2]
        .into_iter()
        .map(|day| {
            let (year, month, date) = civil_from_days(day);
            Path::new(&format!("{year:04}")).join(format!("{month:02}")).join(format!("{date:02}"))
        })
        .collect()
}

/// Howard Hinnant's days-to-civil conversion, for days since 1970-01-01.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let date = (day_of_year - (153 * month_index + 2) / 5 + 1) as u32;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 } as u32;
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, date)
}

fn newest_match(folder: &Path, suffix: &str) -> Option<PathBuf> {
    let mut entries: Vec<PathBuf> = fs::read_dir(folder).ok()?.filter_map(|entry| Some(entry.ok()?.path())).collect();
    entries.sort();
    entries
        .into_iter()
        .rev()
        .find(|path| path.is_file() && path.file_name().is_some_and(|name| name.to_string_lossy().ends_with(suffix)))
}

fn walk(folder: &Path, suffix: &str) -> Option<PathBuf> {
    if let Some(found) = newest_match(folder, suffix) {
        return Some(found);
    }
    let mut folders: Vec<PathBuf> =
        fs::read_dir(folder).ok()?.filter_map(|entry| Some(entry.ok()?.path())).filter(|path| path.is_dir()).collect();
    folders.sort();
    folders.into_iter().rev().find_map(|path| walk(&path, suffix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recent_folders_cover_the_local_today_and_yesterday_of_every_zone() {
        // 2026-11-01T00:30:00Z: still 31 October west of Greenwich, already 1 November east of it.
        let folders = recent_day_folders(1_793_493_000);
        let names: Vec<String> = folders.iter().map(|folder| folder.to_string_lossy().replace('\\', "/")).collect();
        assert_eq!(names, ["2026/11/01", "2026/10/31", "2026/11/02", "2026/10/30"]);
    }

    #[test]
    fn days_convert_across_a_leap_day() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_513), (2026, 3, 1));
        assert_eq!(civil_from_days(19_782), (2024, 2, 29));
    }

    #[test]
    fn a_miss_is_not_searched_again_at_once() {
        let root = std::env::temp_dir().join(format!("peering-codex-miss-{}", std::process::id()));
        let day = root.join("2001").join("01").join("01");
        fs::create_dir_all(&day).expect("folder");
        let mut lookup = LogLookup::default();
        assert_eq!(lookup.find(&root, "late"), None);
        fs::write(day.join("rollout-late.jsonl"), "").expect("log");
        let found = lookup.find(&root, "late").map(Path::to_path_buf);
        let _removed = fs::remove_dir_all(&root);
        assert_eq!(found, None);
    }
}
