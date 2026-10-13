//! The state the tray menu shows and what each menu choice asks the host to do. No toolkit types appear here.

use peering_core::settings::ALLOWED_FRAME_RATES;

use super::settings::{firewall_note, SettingsChoice, SettingsState};
use crate::runtime::{HostSnapshot, OfferView, RelayStatus, RuntimeCommand};
use crate::strings;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    ToggleHosting,
    ShowPairingCode,
    ShowDevices,
    OpenSettings,
    Quit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MenuEntry {
    pub action: MenuAction,
    pub label: &'static str,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MenuModel {
    snapshot: HostSnapshot,
}

impl MenuModel {
    pub fn new(snapshot: HostSnapshot) -> Self {
        Self { snapshot }
    }

    /// The first line of the tooltip and the menu header: hosting state, relay state and the connected phones.
    pub fn status_line(&self) -> String {
        if let Some(reason) = &self.snapshot.stopped {
            return strings::host_stopped(reason);
        }
        let hosting = if self.snapshot.hosting { strings::HOSTING_ON } else { strings::HOSTING_OFF };
        let line = format!("{hosting} · {} · {}", relay_text(self.snapshot.relay), strings::connected_clients(self.snapshot.connected_clients));
        if self.snapshot.problems.is_empty() {
            line
        } else {
            format!("{line} · {}", strings::NEEDS_ATTENTION)
        }
    }

    /// The menu in order. A pairing code only exists while hosting, so its entry is off otherwise.
    pub fn entries(&self) -> Vec<MenuEntry> {
        let hosting = self.snapshot.hosting;
        vec![
            MenuEntry {
                action: MenuAction::ToggleHosting,
                label: if hosting { strings::STOP_HOSTING } else { strings::START_HOSTING },
                enabled: true,
            },
            MenuEntry { action: MenuAction::ShowPairingCode, label: strings::SHOW_PAIRING_CODE, enabled: hosting },
            MenuEntry { action: MenuAction::ShowDevices, label: strings::DEVICES, enabled: true },
            MenuEntry { action: MenuAction::OpenSettings, label: strings::SETTINGS, enabled: true },
            MenuEntry { action: MenuAction::Quit, label: strings::QUIT, enabled: true },
        ]
    }

    /// The command a choice sends to the host. Choices that only change what the window shows send nothing.
    pub fn command_for(&self, action: MenuAction) -> Option<RuntimeCommand> {
        match action {
            MenuAction::ToggleHosting => Some(RuntimeCommand::SetHosting(!self.snapshot.hosting)),
            MenuAction::ShowPairingCode | MenuAction::ShowDevices | MenuAction::OpenSettings | MenuAction::Quit => None,
        }
    }
}

/// What the pairing window shows. The window draws the variant and nothing else.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairingPanel {
    NotHosting,
    /// Hosting with no phone pairing: the QR that identifies this PC.
    Ready { host_qr: String },
    /// A phone is pairing: the code it must match, and the QR that carries the code and the secret.
    Pairing { code: String, client_name: String, code_qr: String, via_relay: bool },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalRow {
    pub prompt: String,
    pub approve: RuntimeCommand,
    pub decline: RuntimeCommand,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRow {
    pub name: String,
    pub last_seen: String,
    pub forget: RuntimeCommand,
}

/// Whether the window offers to start a new paired list, and whether it is asking for the go-ahead first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairedListReset {
    /// The stored list reads fine, so there is nothing to offer.
    Hidden,
    Offered,
    Confirming,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UiModel {
    snapshot: HostSnapshot,
}

impl UiModel {
    pub fn new(snapshot: HostSnapshot) -> Self {
        Self { snapshot }
    }

    pub fn panel(&self) -> PairingPanel {
        if !self.snapshot.hosting {
            return PairingPanel::NotHosting;
        }
        match &self.snapshot.offer {
            Some(OfferView { code, client_name, via_relay, code_link }) => PairingPanel::Pairing {
                code: code.clone(),
                client_name: client_name.clone(),
                code_qr: code_link.clone(),
                via_relay: *via_relay,
            },
            None => PairingPanel::Ready { host_qr: self.snapshot.host_link.clone() },
        }
    }

    pub fn approvals(&self) -> Vec<ApprovalRow> {
        self.snapshot
            .approvals
            .iter()
            .map(|pending| ApprovalRow {
                prompt: strings::approval_prompt(&pending.client_name),
                approve: RuntimeCommand::Approve(pending.id),
                decline: RuntimeCommand::Decline(pending.id),
            })
            .collect()
    }

    /// The paired phones, with how long ago each was last seen as of `now_unix`.
    pub fn devices(&self, now_unix: u64) -> Vec<DeviceRow> {
        self.snapshot
            .devices
            .iter()
            .map(|device| DeviceRow {
                name: device.name.clone(),
                last_seen: strings::last_seen(now_unix.saturating_sub(device.last_seen_unix)),
                forget: RuntimeCommand::Forget(device.id.clone()),
            })
            .collect()
    }

    /// The reset of the paired list: offered only while the stored list cannot be read. `asked` is whether the person has
    /// already pressed the button and is looking at the warning.
    pub fn paired_list_reset(&self, asked: bool) -> PairedListReset {
        match (self.snapshot.paired_list_unreadable, asked) {
            (false, _) => PairedListReset::Hidden,
            (true, false) => PairedListReset::Offered,
            (true, true) => PairedListReset::Confirming,
        }
    }

    /// What is wrong while the host keeps running, one sentence each, for the top of the window.
    pub fn problems(&self) -> &[String] {
        &self.snapshot.problems
    }

    pub fn relay_line(&self) -> &'static str {
        relay_text(self.snapshot.relay)
    }

    /// The settings section: the choices offered, with the frame rate in force marked, and the notes the last actions left.
    pub fn settings(&self, state: &SettingsState) -> SettingsPanel {
        SettingsPanel {
            start_at_login: state.start_at_login(),
            autostart_note: state.autostart_note().map(str::to_owned),
            frame_rates: frame_rate_choices(self.snapshot.frame_rate),
            firewall_note: firewall_note(state.firewall()),
        }
    }
}

/// The settings section as the window draws it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsPanel {
    pub start_at_login: bool,
    pub autostart_note: Option<String>,
    pub frame_rates: Vec<FrameRateChoice>,
    pub firewall_note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameRateChoice {
    pub fps: u32,
    pub label: String,
    pub selected: bool,
}

fn frame_rate_choices(current: u32) -> Vec<FrameRateChoice> {
    ALLOWED_FRAME_RATES
        .into_iter()
        .map(|fps| FrameRateChoice { fps, label: strings::frame_rate_label(fps), selected: fps == current })
        .collect()
}

/// The command a settings choice sends to the host. Start at login and the firewall run on this PC, so they send nothing.
pub fn settings_command(choice: &SettingsChoice) -> Option<RuntimeCommand> {
    match choice {
        SettingsChoice::FrameRate(fps) => Some(RuntimeCommand::SetFrameRate(*fps)),
        SettingsChoice::StartAtLogin(_) | SettingsChoice::FixFirewall => None,
    }
}

fn relay_text(status: RelayStatus) -> &'static str {
    match status {
        RelayStatus::Off => strings::RELAY_OFF,
        RelayStatus::Connecting => strings::RELAY_CONNECTING,
        RelayStatus::Registered => strings::RELAY_REGISTERED,
        RelayStatus::Retrying => strings::RELAY_RETRYING,
        RelayStatus::ClockSkew => strings::RELAY_CLOCK_SKEW,
    }
}

#[cfg(test)]
#[path = "model_tests.rs"]
mod tests;
