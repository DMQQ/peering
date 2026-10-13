//! The application that owns the tray and the window. Windows only, and unverified: it is written against the eframe
//! 0.31 and tray-icon APIs and has not been run on Windows. The window starts hidden; the tray is the entry point, and
//! closing the window hides it again rather than quitting.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use eframe::egui;

use std::path::PathBuf;

use super::jobs::Jobs;
use super::model::{job_command, settings_command, MenuAction, MenuModel, UiModel};
use super::pairing;
use super::settings::{SettingsChoice, SettingsJob, SettingsState};
use super::settings_view;
use super::tray::Tray;
use crate::autostart;
use crate::firewall;
use crate::runtime::{HostHandle, RuntimeCommand};

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
            // `reg` can take seconds, so the box starts unticked and a worker reads the Run entry.
            let jobs = Jobs::default();
            let _unread = jobs.spawn("read-autostart", || SettingsJob::AutostartRead(autostart::is_enabled()));
            Ok(Box::new(HostApp { handle, tray, window_open: false, reset_asked: false, settings: SettingsState::new(false), jobs }))
        }),
    )
}

struct HostApp {
    handle: HostHandle,
    tray: Tray,
    window_open: bool,
    /// The person pressed Reset paired devices and is looking at the warning.
    reset_asked: bool,
    settings: SettingsState,
    jobs: Jobs<SettingsJob>,
}

impl eframe::App for HostApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if ctx.input(|input| input.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.hide_window(ctx);
        }
        let snapshot = self.handle.snapshot();
        for finished in self.jobs.collect() {
            if let Some(command) = job_command(&finished) {
                self.send(ctx, command);
            }
            self.settings.apply(finished);
        }
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
        let port = model.port();
        egui::CentralPanel::default().show(ctx, |ui| {
            for problem in model.problems() {
                ui.colored_label(egui::Color32::from_rgb(200, 60, 40), problem);
            }
            pairing::show(ui, &model, now_unix, &mut self.reset_asked, &mut commands);
            ui.separator();
            settings_view::show(ui, &panel, &mut choices);
        });
        for command in commands {
            self.send(ctx, command);
        }
        for choice in choices {
            self.apply_choice(ctx, choice, port);
        }
    }

    /// Carries out a settings choice. Start at login and the firewall shell out and can take seconds, so they run on a worker
    /// and the result is applied by a later frame; the frame rate goes to the host.
    fn apply_choice(&mut self, ctx: &egui::Context, choice: SettingsChoice, port: u16) {
        match &choice {
            SettingsChoice::StartAtLogin(wanted) => self.change_autostart(*wanted),
            SettingsChoice::FixFirewall => self.fix_firewall(port),
            SettingsChoice::FrameRate(_) | SettingsChoice::RelayEnabled(_) | SettingsChoice::TerminalHooks(_) => {
                if let Some(command) = settings_command(&choice) {
                    self.send(ctx, command);
                }
            }
        }
    }

    fn change_autostart(&mut self, wanted: bool) {
        if !self.settings.begin_autostart() {
            return;
        }
        let started = self.jobs.spawn("autostart", move || {
            let result = program_path().and_then(|path| {
                if wanted {
                    autostart::write_run_key(&path)
                } else {
                    autostart::remove_run_key()
                }
            });
            SettingsJob::AutostartWritten { wanted, result: result.map_err(|error| error.to_string()) }
        });
        if let Err(error) = started {
            self.settings.apply(SettingsJob::AutostartWritten { wanted, result: Err(error.to_string()) });
        }
    }

    fn fix_firewall(&mut self, port: u16) {
        if !self.settings.begin_firewall() {
            return;
        }
        let started = self.jobs.spawn("firewall", move || match program_path() {
            Ok(path) => SettingsJob::Firewall(firewall::request_rule_elevated(&path, port)),
            Err(error) => SettingsJob::Firewall(firewall::HelperResult::CouldNotStart(error.to_string())),
        });
        if let Err(error) = started {
            self.settings.apply(SettingsJob::Firewall(firewall::HelperResult::CouldNotStart(error.to_string())));
        }
    }

    fn send(&self, ctx: &egui::Context, command: RuntimeCommand) {
        // The runtime has stopped, so nothing can answer the request: the application closes instead.
        if !self.handle.send(command) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }
}
