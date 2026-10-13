//! The settings section of the window (Windows only). Unverified: written against the egui 0.31 API and not run on Windows. It
//! draws the values `UiModel::settings` gives and reports the choices the controls made.

use eframe::egui;

use super::model::SettingsPanel;
use super::settings::SettingsChoice;
use crate::strings;

pub fn show(ui: &mut egui::Ui, panel: &SettingsPanel, choices: &mut Vec<SettingsChoice>) {
    ui.heading(strings::SETTINGS);
    let mut start_at_login = panel.start_at_login;
    if ui.checkbox(&mut start_at_login, strings::START_AT_LOGIN).changed() {
        choices.push(SettingsChoice::StartAtLogin(start_at_login));
    }
    if let Some(note) = &panel.autostart_note {
        ui.label(note.as_str());
    }
    let mut relay_enabled = panel.relay_enabled;
    if ui.checkbox(&mut relay_enabled, strings::RELAY_ENABLED).changed() {
        choices.push(SettingsChoice::RelayEnabled(relay_enabled));
    }
    let mut terminal_hooks = panel.terminal_hooks;
    if ui.checkbox(&mut terminal_hooks, strings::TERMINAL_HOOKS).changed() {
        choices.push(SettingsChoice::TerminalHooks(terminal_hooks));
    }
    ui.label(strings::TERMINAL_HOOKS_HINT);
    if ui.button(strings::FIX_FIREWALL).clicked() {
        choices.push(SettingsChoice::FixFirewall);
    }
    ui.label(strings::FIREWALL_HINT);
    if let Some(note) = &panel.firewall_note {
        ui.label(note.as_str());
    }
    ui.label(strings::FRAME_RATE_HEADING);
    ui.horizontal(|ui| {
        for choice in &panel.frame_rates {
            if ui.radio(choice.selected, choice.label.as_str()).clicked() {
                choices.push(SettingsChoice::FrameRate(choice.fps));
            }
        }
    });
    ui.label(strings::FRAME_RATE_NOTE);
}
