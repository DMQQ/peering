//! The state the tray menu shows and what each menu choice asks the host to do. No toolkit types appear here.

use crate::runtime::{HostSnapshot, RelayStatus, RuntimeCommand};
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
        let hosting = if self.snapshot.hosting { strings::HOSTING_ON } else { strings::HOSTING_OFF };
        format!("{hosting} · {} · {}", relay_text(self.snapshot.relay), strings::connected_clients(self.snapshot.connected_clients))
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
            // The settings window is not built yet, so its entry is shown but cannot be chosen.
            MenuEntry { action: MenuAction::OpenSettings, label: strings::SETTINGS, enabled: false },
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

fn relay_text(status: RelayStatus) -> &'static str {
    match status {
        RelayStatus::Off => strings::RELAY_OFF,
        RelayStatus::Connecting => strings::RELAY_CONNECTING,
        RelayStatus::Registered => strings::RELAY_REGISTERED,
        RelayStatus::Retrying => strings::RELAY_RETRYING,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(hosting: bool, relay: RelayStatus, clients: usize) -> HostSnapshot {
        HostSnapshot { hosting, relay, connected_clients: clients, ..HostSnapshot::default() }
    }

    fn label_of(model: &MenuModel, action: MenuAction) -> &'static str {
        model.entries().into_iter().find(|entry| entry.action == action).expect("the entry exists").label
    }

    #[test]
    fn the_first_entry_offers_to_stop_while_hosting_and_to_start_otherwise() {
        assert_eq!(label_of(&MenuModel::new(snapshot(true, RelayStatus::Off, 0)), MenuAction::ToggleHosting), strings::STOP_HOSTING);
        assert_eq!(label_of(&MenuModel::new(snapshot(false, RelayStatus::Off, 0)), MenuAction::ToggleHosting), strings::START_HOSTING);
    }

    #[test]
    fn the_pairing_code_is_offered_only_while_hosting() {
        let hosting = MenuModel::new(snapshot(true, RelayStatus::Off, 0));
        let stopped = MenuModel::new(snapshot(false, RelayStatus::Off, 0));
        let enabled = |model: &MenuModel| {
            model.entries().into_iter().find(|entry| entry.action == MenuAction::ShowPairingCode).expect("present").enabled
        };
        assert!(enabled(&hosting));
        assert!(!enabled(&stopped));
    }

    #[test]
    fn settings_is_listed_but_cannot_be_chosen_yet() {
        let model = MenuModel::new(snapshot(true, RelayStatus::Off, 0));
        let settings = model.entries().into_iter().find(|entry| entry.action == MenuAction::OpenSettings).expect("present");
        assert!(!settings.enabled);
    }

    #[test]
    fn the_menu_lists_the_five_entries_in_order() {
        let actions: Vec<MenuAction> =
            MenuModel::new(snapshot(true, RelayStatus::Off, 0)).entries().iter().map(|entry| entry.action).collect();
        assert_eq!(
            actions,
            vec![
                MenuAction::ToggleHosting,
                MenuAction::ShowPairingCode,
                MenuAction::ShowDevices,
                MenuAction::OpenSettings,
                MenuAction::Quit,
            ]
        );
    }

    #[test]
    fn toggling_hosting_asks_the_host_for_the_opposite_state() {
        let hosting = MenuModel::new(snapshot(true, RelayStatus::Off, 0));
        assert_eq!(hosting.command_for(MenuAction::ToggleHosting), Some(RuntimeCommand::SetHosting(false)));
        let stopped = MenuModel::new(snapshot(false, RelayStatus::Off, 0));
        assert_eq!(stopped.command_for(MenuAction::ToggleHosting), Some(RuntimeCommand::SetHosting(true)));
    }

    #[test]
    fn navigation_and_quit_send_no_command() {
        let model = MenuModel::new(snapshot(true, RelayStatus::Off, 0));
        for action in [MenuAction::ShowPairingCode, MenuAction::ShowDevices, MenuAction::OpenSettings, MenuAction::Quit] {
            assert_eq!(model.command_for(action), None);
        }
    }

    #[test]
    fn the_status_line_names_hosting_the_relay_and_the_phones() {
        let model = MenuModel::new(snapshot(true, RelayStatus::Registered, 2));
        assert_eq!(model.status_line(), "Hosting · Relay connected · 2 phones connected");
        let stopped = MenuModel::new(snapshot(false, RelayStatus::Retrying, 0));
        assert_eq!(stopped.status_line(), "Not hosting · Relay retrying · No phone connected");
    }

    #[test]
    fn a_single_phone_is_counted_in_the_singular() {
        assert_eq!(strings::connected_clients(1), "1 phone connected");
    }
}
