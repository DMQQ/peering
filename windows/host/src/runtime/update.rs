//! Tells the person in the window that a newer Windows build exists. The look is a request for the repository's releases, made
//! at most once a day while the setting is on and a phone or not; what comes back is judged by `peering_core::update`. Nothing
//! is downloaded or installed here: the notice links to the release page.

mod fetch;

use std::sync::Arc;
use std::time::Duration;

use peering_core::update::{newest_release, notice_for, CheckSchedule, UpdateNotice};
use tokio::task::{spawn_local, JoinHandle};
use tokio::time::interval;

use super::diagnostics;
use super::shared::Shared;
use super::HostProfile;
pub use fetch::GithubReleases;

const TICK: Duration = Duration::from_secs(30);

/// Where the list of releases comes from: GitHub's answer as text, or why there is none.
pub trait ReleaseSource: Send + Sync {
    fn fetch(&self) -> Result<String, String>;
}

/// The source of a host that never asks anyone anything: tests, and a build for a machine with no network access.
pub struct NoReleases;

impl ReleaseSource for NoReleases {
    fn fetch(&self) -> Result<String, String> {
        Err("this host does not check for updates".to_owned())
    }
}

/// What one look found, as the state records it. A failed look keeps the notice from the last good one.
pub(super) fn judge(running: &str, answer: Result<String, String>) -> Result<Option<UpdateNotice>, String> {
    let json = answer?;
    let newest = newest_release(&json).map_err(|error| error.to_string())?;
    Ok(newest.and_then(|release| notice_for(running, &release)))
}

async fn run(shared: Shared, profile: Arc<HostProfile>, source: Arc<dyn ReleaseSource>, running: &'static str) {
    let mut ticks = interval(TICK);
    let mut schedule = CheckSchedule::starting_at(profile.clock.now_seconds());
    loop {
        ticks.tick().await;
        let now = profile.clock.now_seconds();
        let wanted = shared.lock().settings.check_for_updates;
        if !wanted {
            shared.lock().update = None;
            continue;
        }
        if !schedule.due(now) {
            continue;
        }
        let fetching = source.clone();
        let answer = tokio::task::spawn_blocking(move || fetching.fetch()).await.unwrap_or_else(|_| Err("the check did not finish".to_owned()));
        let judged = judge(running, answer);
        schedule.looked(now, judged.is_ok());
        let mut state = shared.lock();
        match judged {
            Ok(notice) => state.update = notice,
            Err(reason) => diagnostics::log(&format!("the update check failed: {reason}")),
        }
    }
}

pub fn spawn(shared: Shared, profile: Arc<HostProfile>, source: Arc<dyn ReleaseSource>, running: &'static str) -> JoinHandle<()> {
    spawn_local(run(shared, profile, source, running))
}

#[cfg(test)]
mod tests;
