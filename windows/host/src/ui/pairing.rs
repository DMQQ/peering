//! The pairing window (Windows only). Unverified: written against the egui 0.31 API and not run on Windows. It draws
//! the values `UiModel` gives and returns the commands the buttons chose.

use eframe::egui;

use super::model::{PairedListReset, PairingPanel, UiModel};
use super::qr::modules_for;
use crate::runtime::RuntimeCommand;
use crate::strings;

const QR_SIDE: f32 = 240.0;
const QUIET_ZONE_MODULES: usize = 4;

pub fn show(ui: &mut egui::Ui, model: &UiModel, now_unix: u64, reset_asked: &mut bool, commands: &mut Vec<RuntimeCommand>) {
    ui.heading(strings::PAIRING_TITLE);
    show_panel(ui, model);
    ui.separator();
    show_approvals(ui, model, commands);
    ui.separator();
    show_devices(ui, model, now_unix, commands);
    show_reset(ui, model, reset_asked, commands);
}

fn show_panel(ui: &mut egui::Ui, model: &UiModel) {
    match model.panel() {
        PairingPanel::NotHosting => {
            ui.label(strings::NEEDS_HOSTING);
        }
        PairingPanel::Ready { host_qr } => {
            ui.label(strings::SCAN_TO_FIND_HOST);
            draw_qr(ui, &host_qr);
        }
        PairingPanel::Pairing { code, client_name, code_qr, via_relay } => {
            ui.label(strings::pairing_with(&client_name));
            ui.heading(code);
            ui.label(strings::CODE_HEADING);
            draw_qr(ui, &code_qr);
            if via_relay {
                ui.label(strings::RELAY_PAIRING_NOTE);
            }
        }
    }
}

fn show_approvals(ui: &mut egui::Ui, model: &UiModel, commands: &mut Vec<RuntimeCommand>) {
    for approval in model.approvals() {
        ui.label(approval.prompt);
        if ui.button(strings::APPROVE).clicked() {
            commands.push(approval.approve);
        }
        if ui.button(strings::DECLINE).clicked() {
            commands.push(approval.decline);
        }
    }
}

fn show_devices(ui: &mut egui::Ui, model: &UiModel, now_unix: u64, commands: &mut Vec<RuntimeCommand>) {
    ui.heading(strings::DEVICES_HEADING);
    let devices = model.devices(now_unix);
    if devices.is_empty() {
        ui.label(strings::NO_DEVICES);
    }
    for device in devices {
        ui.label(format!("{} · {}", device.name, device.last_seen));
        if ui.button(strings::FORGET).clicked() {
            commands.push(device.forget);
        }
    }
}

fn show_reset(ui: &mut egui::Ui, model: &UiModel, asked: &mut bool, commands: &mut Vec<RuntimeCommand>) {
    match model.paired_list_reset(*asked) {
        PairedListReset::Hidden => *asked = false,
        PairedListReset::Offered => {
            if ui.button(strings::RESET_PAIRED_DEVICES).clicked() {
                *asked = true;
            }
        }
        PairedListReset::Confirming => {
            ui.label(strings::RESET_PAIRED_DEVICES_WARNING);
            if ui.button(strings::RESET_CONFIRM).clicked() {
                commands.push(RuntimeCommand::ResetPairedDevices);
                *asked = false;
            }
            if ui.button(strings::RESET_CANCEL).clicked() {
                *asked = false;
            }
        }
    }
}

fn draw_qr(ui: &mut egui::Ui, content: &str) {
    let Some(modules) = modules_for(content) else {
        ui.label(strings::CODE_TOO_LONG);
        return;
    };
    let span = modules.width + 2 * QUIET_ZONE_MODULES;
    let cell = QR_SIDE / span as f32;
    let (rect, _response) = ui.allocate_exact_size(egui::vec2(QR_SIDE, QR_SIDE), egui::Sense::hover());
    let painter = ui.painter_at(rect);
    painter.rect_filled(rect, 0.0, egui::Color32::WHITE);
    for y in 0..modules.width {
        for x in 0..modules.width {
            if !modules.is_dark(x, y) {
                continue;
            }
            let origin = rect.min
                + egui::vec2((x + QUIET_ZONE_MODULES) as f32 * cell, (y + QUIET_ZONE_MODULES) as f32 * cell);
            let module = egui::Rect::from_min_size(origin, egui::vec2(cell, cell));
            painter.rect_filled(module, 0.0, egui::Color32::BLACK);
        }
    }
}
