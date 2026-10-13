//! What the settings section holds between draws: start at login, the firewall helper's last result, and the choices the
//! window's controls report. The window draws `UiModel::settings` and reports `SettingsChoice`s; nothing here touches the OS.

use crate::firewall::HelperResult;
use crate::strings;

/// What the last "Fix firewall" request reported.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum FirewallOutcome {
    #[default]
    NotRequested,
    /// The elevated helper was started. Windows asks the user to approve it, and the rule exists only after that.
    Requested,
    /// The helper finished and found the rules again.
    Applied,
    Refused(String),
}

impl From<HelperResult> for FirewallOutcome {
    fn from(result: HelperResult) -> Self {
        match result.failure_reason() {
            None => Self::Applied,
            Some(reason) => Self::Refused(reason),
        }
    }
}

/// What a finished background job tells the settings section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsJob {
    /// What the Run entry said when the window opened.
    AutostartRead(bool),
    AutostartWritten { wanted: bool, result: Result<(), String> },
    Firewall(HelperResult),
}

/// A control the user changed in the settings section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsChoice {
    StartAtLogin(bool),
    FixFirewall,
    FrameRate(u32),
    RelayEnabled(bool),
    TerminalHooks(bool),
    CheckForUpdates(bool),
    /// Opens the folder the log files are in.
    OpenLogs,
    /// Opens the release page of the newer build in the browser.
    OpenUpdatePage(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsState {
    start_at_login: bool,
    autostart_note: Option<String>,
    firewall: FirewallOutcome,
    autostart_pending: bool,
}

impl SettingsState {
    /// `start_at_login` is what the Run entry says when the window opens.
    pub fn new(start_at_login: bool) -> Self {
        Self { start_at_login, autostart_note: None, firewall: FirewallOutcome::NotRequested, autostart_pending: false }
    }

    pub fn start_at_login(&self) -> bool {
        self.start_at_login
    }

    pub fn autostart_note(&self) -> Option<&str> {
        self.autostart_note.as_deref()
    }

    pub fn firewall(&self) -> &FirewallOutcome {
        &self.firewall
    }

    /// The result of a start-at-login change. A change that failed leaves the box where it was, with the reason shown.
    pub fn record_autostart(&mut self, wanted: bool, result: Result<(), String>) {
        match result {
            Ok(()) => {
                self.start_at_login = wanted;
                self.autostart_note = None;
            }
            Err(reason) => self.autostart_note = Some(strings::autostart_failed(&reason)),
        }
    }

    pub fn record_firewall(&mut self, outcome: FirewallOutcome) {
        self.firewall = outcome;
    }

    /// Marks a start-at-login change as running. False when one already is, and the new request is dropped.
    pub fn begin_autostart(&mut self) -> bool {
        !std::mem::replace(&mut self.autostart_pending, true)
    }

    /// Marks the firewall request as running. False when one already is, and the new request is dropped.
    pub fn begin_firewall(&mut self) -> bool {
        if self.firewall == FirewallOutcome::Requested {
            return false;
        }
        self.firewall = FirewallOutcome::Requested;
        true
    }

    /// A background job finished.
    pub fn apply(&mut self, job: SettingsJob) {
        match job {
            SettingsJob::AutostartRead(enabled) => self.start_at_login = enabled,
            SettingsJob::AutostartWritten { wanted, result } => {
                self.autostart_pending = false;
                self.record_autostart(wanted, result);
            }
            SettingsJob::Firewall(result) => self.firewall = result.into(),
        }
    }
}

/// The text under the firewall button, or nothing before the first request.
pub fn firewall_note(outcome: &FirewallOutcome) -> Option<String> {
    match outcome {
        FirewallOutcome::NotRequested => None,
        FirewallOutcome::Requested => Some(strings::FIREWALL_REQUESTED.to_owned()),
        FirewallOutcome::Applied => Some(strings::FIREWALL_APPLIED.to_owned()),
        FirewallOutcome::Refused(reason) => Some(strings::firewall_refused(reason)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_finished_helper_that_applied_the_rule_says_so() {
        let mut state = SettingsState::new(false);
        assert!(state.begin_firewall());
        assert_eq!(firewall_note(state.firewall()).as_deref(), Some(strings::FIREWALL_REQUESTED));
        state.apply(SettingsJob::Firewall(HelperResult::Applied));
        assert_eq!(firewall_note(state.firewall()).as_deref(), Some(strings::FIREWALL_APPLIED));
    }

    #[test]
    fn a_helper_that_failed_shows_its_real_reason() {
        let mut state = SettingsState::new(false);
        state.begin_firewall();
        state.apply(SettingsJob::Firewall(HelperResult::Failed(1)));
        let note = firewall_note(state.firewall()).expect("a note");
        assert!(note.contains("exit code 1"), "{note}");
    }

    #[test]
    fn a_declined_prompt_is_not_reported_as_a_success() {
        let mut state = SettingsState::new(false);
        state.begin_firewall();
        state.apply(SettingsJob::Firewall(HelperResult::Declined));
        assert_eq!(*state.firewall(), FirewallOutcome::Refused("the Windows prompt was declined".to_owned()));
    }

    #[test]
    fn a_second_firewall_request_while_one_runs_is_dropped() {
        let mut state = SettingsState::new(false);
        assert!(state.begin_firewall());
        assert!(!state.begin_firewall());
        state.apply(SettingsJob::Firewall(HelperResult::TimedOut));
        assert!(state.begin_firewall());
    }

    #[test]
    fn a_second_autostart_change_while_one_runs_is_dropped() {
        let mut state = SettingsState::new(false);
        assert!(state.begin_autostart());
        assert!(!state.begin_autostart());
        state.apply(SettingsJob::AutostartWritten { wanted: true, result: Ok(()) });
        assert!(state.start_at_login());
        assert!(state.begin_autostart());
    }

    #[test]
    fn a_failed_autostart_change_leaves_the_box_and_shows_the_reason() {
        let mut state = SettingsState::new(false);
        state.begin_autostart();
        state.apply(SettingsJob::AutostartWritten { wanted: true, result: Err("it did not finish in time".to_owned()) });
        assert!(!state.start_at_login());
        assert!(state.autostart_note().is_some_and(|note| note.contains("did not finish")));
    }

    #[test]
    fn the_run_entry_read_after_the_window_opens_sets_the_box() {
        let mut state = SettingsState::new(false);
        state.apply(SettingsJob::AutostartRead(true));
        assert!(state.start_at_login());
    }
}
