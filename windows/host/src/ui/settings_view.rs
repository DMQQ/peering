//! The settings section of the window (Windows only). Unverified: written against the egui 0.31 API and not run on Windows. It
//! draws the values `UiModel::settings` gives and reports the choices the controls made.

use eframe::egui;

use super::model::SettingsPanel;
use super::settings::SettingsChoice;
use super::theme;
use crate::strings;

pub fn show(ui: &mut egui::Ui, panel: &SettingsPanel, choices: &mut Vec<SettingsChoice>) {
    theme::card(ui, |ui| {
        theme::title(ui, strings::SETTINGS);
        switches(ui, panel, choices);
    });
    theme::card(ui, |ui| {
        theme::title(ui, strings::FRAME_RATE_HEADING);
        ui.horizontal(|ui| {
            for choice in &panel.frame_rates {
                if ui.selectable_label(choice.selected, choice.label.as_str()).clicked() {
                    choices.push(SettingsChoice::FrameRate(choice.fps));
                }
            }
        });
        theme::hint(ui, strings::FRAME_RATE_NOTE);
    });
    theme::card(ui, |ui| maintenance(ui, panel, choices));
}

/// A prompt that cannot be missed, drawn above everything else while the firewall rules are missing or out of date.
pub fn firewall_prompt(ui: &mut egui::Ui, panel: &SettingsPanel, choices: &mut Vec<SettingsChoice>) {
    if !panel.firewall_needed {
        return;
    }
    egui::Frame::new()
        .fill(theme::DANGER.gamma_multiply(0.14))
        .stroke(egui::Stroke::new(1.5_f32, theme::DANGER))
        .corner_radius(egui::CornerRadius::same(14))
        .inner_margin(egui::Margin::same(20))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(egui::RichText::new(strings::FIREWALL_PROMPT_TITLE).size(22.0).strong().color(egui::Color32::WHITE));
            ui.add_space(6.0);
            ui.label(egui::RichText::new(strings::FIREWALL_PROMPT_BODY).size(15.0).color(egui::Color32::WHITE));
            ui.add_space(12.0);
            ui.add_enabled_ui(!panel.firewall_running, |ui| {
                let button = egui::Button::new(egui::RichText::new(strings::FIREWALL_PROMPT_BUTTON).size(17.0).strong().color(egui::Color32::WHITE))
                    .fill(theme::ACCENT)
                    .min_size(egui::vec2(ui.available_width(), 44.0));
                if ui.add(button).clicked() {
                    choices.push(SettingsChoice::FixFirewall);
                }
            });
            if let Some(note) = &panel.firewall_note {
                ui.add_space(8.0);
                ui.label(theme::muted(note));
            }
        });
    ui.add_space(12.0);
}

fn switches(ui: &mut egui::Ui, panel: &SettingsPanel, choices: &mut Vec<SettingsChoice>) {
    let mut start_at_login = panel.start_at_login;
    if theme::switch_row(ui, &mut start_at_login, strings::START_AT_LOGIN, panel.autostart_note.as_deref()) {
        choices.push(SettingsChoice::StartAtLogin(start_at_login));
    }
    let mut relay_enabled = panel.relay_enabled;
    if theme::switch_row(ui, &mut relay_enabled, strings::RELAY_ENABLED, None) {
        choices.push(SettingsChoice::RelayEnabled(relay_enabled));
    }
    let mut terminal_hooks = panel.terminal_hooks;
    if theme::switch_row(ui, &mut terminal_hooks, strings::TERMINAL_HOOKS, Some(strings::TERMINAL_HOOKS_HINT)) {
        choices.push(SettingsChoice::TerminalHooks(terminal_hooks));
    }
    let mut check_for_updates = panel.check_for_updates;
    if theme::switch_row(ui, &mut check_for_updates, strings::CHECK_FOR_UPDATES, Some(strings::CHECK_FOR_UPDATES_HINT)) {
        choices.push(SettingsChoice::CheckForUpdates(check_for_updates));
    }
}

fn maintenance(ui: &mut egui::Ui, panel: &SettingsPanel, choices: &mut Vec<SettingsChoice>) {
    if let Some(update) = &panel.update {
        ui.label(egui::RichText::new(strings::update_available(&update.version)).color(theme::SUCCESS));
        if theme::primary_button(ui, strings::OPEN_DOWNLOAD).clicked() {
            choices.push(SettingsChoice::OpenUpdatePage(update.page.clone()));
        }
    }
    if ui.button(strings::FIX_FIREWALL).clicked() {
        choices.push(SettingsChoice::FixFirewall);
    }
    theme::hint(ui, strings::FIREWALL_HINT);
    if let Some(note) = &panel.firewall_note {
        ui.label(theme::muted(note));
    }
    if ui.button(strings::OPEN_LOGS).clicked() {
        choices.push(SettingsChoice::OpenLogs);
    }
    theme::hint(ui, strings::OPEN_LOGS_HINT);
}
