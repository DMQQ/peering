//! The application that owns the tray and the window. Windows only, and unverified: it is written against the eframe
//! 0.31 and tray-icon APIs and has not been run on Windows. The window starts hidden; the tray is the entry point, and
//! closing the window hides it again rather than quitting.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use eframe::egui;

use std::path::PathBuf;

use super::model::{settings_command, MenuAction, MenuModel, UiModel};
use super::pairing;
use super::settings::{FirewallOutcome, SettingsChoice, SettingsState};
use super::settings_view;
use super::tray::Tray;
use crate::autostart;
use crate::firewall;
use crate::runtime::{HostHandle, RuntimeCommand, DEFAULT_PORT};

const POLL_INTERVAL: Duration = Duration::from_millis(250);

pub fn run(handle: HostHandle) -> Result<(), eframe::Error> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_visible(false).with_inner_size([420.0, 620.0]),
        ..Default::default()
    };
    eframe::run_native(
        crate::strings::TOOLTIP,
        options,
        Box::new(move |_creation| {
            let model = MenuModel::new(handle.snapshot());
            let tray = Tray::new(&model.entries())?;
            let settings = SettingsState::new(autostart::is_enabled());
            Ok(Box::new(HostApp { handle, tray, window_open: false, settings }))
        }),
    )
}

struct HostApp {
    handle: HostHandle,
    tray: Tray,
    window_open: bool,
    settings: SettingsState,
}

impl eframe::App for HostApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if ctx.input(|input| input.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.hide_window(ctx);
        }
        let snapshot = self.handle.snapshot();
        let menu = MenuModel::new(snapshot.clone());
        self.tray.update(&menu.entries(), &menu.status_line());
        while let Some(action) = self.tray.poll() {
            self.choose(ctx, &menu, action);
        }
        if self.window_open {
            self.draw_window(ctx, UiModel::new(snapshot));
        }
        ctx.request_repaint_after(POLL_INTERVAL);
    }
}

fn program_path() -> std::io::Result<PathBuf> {
    std::env::current_exe()
}

impl HostApp {
    fn choose(&mut self, ctx: &egui::Context, menu: &MenuModel, action: MenuAction) {
        match action {
            MenuAction::Quit => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            MenuAction::ShowPairingCode | MenuAction::ShowDevices | MenuAction::OpenSettings => self.show_window(ctx),
            MenuAction::ToggleHosting => {
                if let Some(command) = menu.command_for(action) {
                    self.send(ctx, command);
                }
            }
        }
    }

    fn show_window(&mut self, ctx: &egui::Context) {
        self.window_open = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
    }

    fn hide_window(&mut self, ctx: &egui::Context) {
        self.window_open = false;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
    }

    fn draw_window(&mut self, ctx: &egui::Context, model: UiModel) {
        let mut commands = Vec::new();
        let mut choices = Vec::new();
        let now_unix = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs());
        let panel = model.settings(&self.settings);
        egui::CentralPanel::default().show(ctx, |ui| {
            for problem in model.problems() {
                ui.colored_label(egui::Color32::from_rgb(200, 60, 40), problem);
            }
            pairing::show(ui, &model, now_unix, &mut commands);
            ui.separator();
            settings_view::show(ui, &panel, &mut choices);
        });
        for command in commands {
            self.send(ctx, command);
        }
        for choice in choices {
            self.apply_choice(ctx, choice);
        }
    }

    /// Carries out a settings choice. Start at login and the firewall run here, on the window's thread; the frame rate goes
    /// to the host.
    fn apply_choice(&mut self, ctx: &egui::Context, choice: SettingsChoice) {
        match &choice {
            SettingsChoice::StartAtLogin(wanted) => {
                let result = program_path().and_then(|path| {
                    if *wanted {
                        autostart::write_run_key(&path)
                    } else {
                        autostart::remove_run_key()
                    }
                });
                self.settings.record_autostart(*wanted, result.map_err(|error| error.to_string()));
            }
            SettingsChoice::FixFirewall => {
                let outcome = match program_path().and_then(|path| firewall::request_rule_elevated(&path, DEFAULT_PORT)) {
                    Ok(()) => FirewallOutcome::Requested,
                    Err(error) => FirewallOutcome::Refused(error.to_string()),
                };
                self.settings.record_firewall(outcome);
            }
            SettingsChoice::FrameRate(_) => {
                if let Some(command) = settings_command(&choice) {
                    self.send(ctx, command);
                }
            }
        }
    }

    fn send(&self, ctx: &egui::Context, command: RuntimeCommand) {
        // The runtime has stopped, so nothing can answer the request: the application closes instead.
        if !self.handle.send(command) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }
}
