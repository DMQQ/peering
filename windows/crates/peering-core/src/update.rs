//! Knowing that a newer Windows release exists. The host asks GitHub for the repository's releases, takes the newest one tagged
//! `windows-v<version>` and, when it is newer than the running build, tells the person in the window. Nothing is downloaded or
//! installed: the notice links to the release page, where the unsigned installer is. The Mac host does this with Sparkle.

use std::cmp::Ordering;

use serde::Deserialize;
use thiserror::Error;

/// Where a release page lives. A link from anywhere else is not shown, whatever the answer says.
pub const RELEASE_PAGE_PREFIX: &str = "https://github.com/DMQQ/peering/releases/";
const TAG_PREFIX: &str = "windows-v";

/// Seconds after the host starts before the first look, so a start at login does not compete with the PC coming up.
const FIRST_CHECK_DELAY: f64 = 60.0;
const AFTER_SUCCESS: f64 = 24.0 * 3600.0;
const AFTER_FAILURE: f64 = 3600.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl Version {
    /// `1.2.3`, `1.2` or `1`, with or without a `windows-v` or `v` in front. Anything else, such as `1.2.3-rc1`, is no
    /// release a person should be sent to.
    pub fn parse(text: &str) -> Option<Self> {
        let digits = text.strip_prefix(TAG_PREFIX).or_else(|| text.strip_prefix('v')).unwrap_or(text);
        let components: Vec<&str> = digits.split('.').collect();
        if components.len() > 3 {
            return None;
        }
        let number = |component: &str| -> Option<u32> {
            if component.is_empty() || !component.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            component.parse().ok()
        };
        let at = |index: usize| components.get(index).map_or(Some(0), |component| number(component));
        Some(Self { major: number(components[0])?, minor: at(1)?, patch: at(2)? })
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub version: Version,
    pub page: String,
}

/// What the window tells the person: a newer version exists, and where to get it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateNotice {
    pub version: String,
    pub page: String,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum UpdateError {
    #[error("the release list could not be read: {0}")]
    Unreadable(String),
}

#[derive(Deserialize)]
struct ApiRelease {
    tag_name: String,
    html_url: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    prerelease: bool,
}

/// The newest published Windows release in GitHub's list of releases, or `None` when there is none.
pub fn newest_release(json: &str) -> Result<Option<Release>, UpdateError> {
    let releases: Vec<ApiRelease> = serde_json::from_str(json).map_err(|error| UpdateError::Unreadable(error.to_string()))?;
    Ok(releases
        .into_iter()
        .filter(|release| !release.draft && !release.prerelease && release.tag_name.starts_with(TAG_PREFIX))
        .filter(|release| release.html_url.starts_with(RELEASE_PAGE_PREFIX))
        .filter_map(|release| Some(Release { version: Version::parse(&release.tag_name)?, page: release.html_url }))
        .max_by_key(|release| release.version))
}

/// The notice for `release` when it is newer than `running`, else nothing. A running version that cannot be read gets none,
/// since there is no telling what is newer than it.
pub fn notice_for(running: &str, release: &Release) -> Option<UpdateNotice> {
    let running = Version::parse(running)?;
    (release.version.cmp(&running) == Ordering::Greater)
        .then(|| UpdateNotice { version: release.version.to_string(), page: release.page.clone() })
}

/// When to look next.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CheckSchedule {
    next_at: f64,
}

impl CheckSchedule {
    pub fn starting_at(now: f64) -> Self {
        Self { next_at: now + FIRST_CHECK_DELAY }
    }

    pub fn due(&self, now: f64) -> bool {
        now >= self.next_at
    }

    pub fn looked(&mut self, now: f64, succeeded: bool) {
        self.next_at = now + if succeeded { AFTER_SUCCESS } else { AFTER_FAILURE };
    }
}

#[cfg(test)]
mod tests;
