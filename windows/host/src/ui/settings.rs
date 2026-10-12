//! What the settings section holds between draws: start at login, the firewall helper's last result, and the choices the
//! window's controls report. The window draws `UiModel::settings` and reports `SettingsChoice`s; nothing here touches the OS.

use crate::strings;

/// What the last "Fix firewall" request reported.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum FirewallOutcome {
    #[default]
    NotRequested,
    /// The elevated helper was started. Windows asks the user to approve it, and the rule exists only after that.
    Requested,
    Refused(String),
}

/// A control the user changed in the settings section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsChoice {
    StartAtLogin(bool),
    FixFirewall,
    FrameRate(u32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsState {
    start_at_login: bool,
    autostart_note: Option<String>,
    firewall: FirewallOutcome,
}

impl SettingsState {
    /// `start_at_login` is what the Run entry says when the window opens.
    pub fn new(start_at_login: bool) -> Self {
        Self { start_at_login, autostart_note: None, firewall: FirewallOutcome::NotRequested }
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
}

/// The text under the firewall button, or nothing before the first request.
pub fn firewall_note(outcome: &FirewallOutcome) -> Option<String> {
    match outcome {
        FirewallOutcome::NotRequested => None,
        FirewallOutcome::Requested => Some(strings::FIREWALL_REQUESTED.to_owned()),
        FirewallOutcome::Refused(reason) => Some(strings::firewall_refused(reason)),
    }
}
