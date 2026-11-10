//! The application that owns the tray and the window. Windows only, and unverified: it is written against the eframe
//! 0.31 and tray-icon APIs and has not been run on Windows. The window starts hidden; the tray is the entry point, and
//! closing the window hides it again rather than quitting.

use std::cell::Cell;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use eframe::egui;
use peering_platform::single_instance::Guard;

use std::path::PathBuf;

use super::icon;
use super::jobs::Jobs;
use super::model::{job_command, settings_command, MenuAction, MenuModel, UiModel};
use super::pairing;
use super::settings::{SettingsChoice, SettingsJob, SettingsState};
use super::settings_view;
use super::theme;
use super::tray::Tray;
use super::window_control::WindowControl;
use crate::autostart;
use crate::firewall;
use crate::runtime::{HostHandle, RuntimeCommand};

const POLL_INTERVAL: Duration = Duration::from_millis(250);

pub fn run(handle: HostHandle, instance: Guard) -> Result<(), eframe::Error> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_visible(false)
            .with_inner_size([480.0, 760.0])
            .with_min_inner_size([380.0, 480.0])
            .with_icon(egui::IconData { rgba: icon::RGBA.to_vec(), width: icon::SIDE, height: icon::SIDE }),
        ..Default::default()
    };
    eframe::run_native(
        crate::strings::TOOLTIP,
        options,
        Box::new(move |creation| {
            theme::apply(&creation.egui_ctx);
            let model = MenuModel::new(handle.snapshot());
            let window = WindowControl::of(creation);
            let instance = Arc::new(instance);
            watch_show_requests(&instance, &window);
            let tray = Tray::new(&model.entries(), tray_choice(handle.clone(), window))?;
            // `reg` can take seconds, so the box starts unticked and a worker reads the Run entry.
            let jobs = Jobs::default();
            let _unread = jobs.spawn("read-autostart", || SettingsJob::AutostartRead(autostart::is_enabled()));
            let port = handle.snapshot().port;
            let _checked = jobs.spawn("check-firewall", move || {
                let in_place = program_path().is_ok_and(|path| firewall::rule_in_place(&path, port));
                SettingsJob::FirewallChecked { in_place }
            });
            Ok(Box::new(HostApp { _instance: instance, handle, tray, reset_asked: false, settings: SettingsState::new(false), jobs, quitting: Cell::new(false) }))
        }),
    )
}

struct HostApp {
    /// Held for the life of the app: dropping it frees the name for the next launch. A thread waits on it for launches that were turned away.
    _instance: Arc<Guard>,
    handle: HostHandle,
    tray: Tray,
    /// The person pressed Reset paired devices and is looking at the warning.
    reset_asked: bool,
    settings: SettingsState,
    jobs: Jobs<SettingsJob>,
    /// Quit was chosen, so the close request that follows is the real one and must not be turned into a hide.
    quitting: Cell<bool>,
}

impl eframe::App for HostApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if !self.quitting.get() && ctx.input(|input| input.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.hide_window(ctx);
        }
        let snapshot = self.handle.snapshot();
        for finished in self.jobs.collect() {
            // The window starts hidden behind the tray, and a person who never opens it would never see the prompt.
            if matches!(finished, SettingsJob::FirewallChecked { in_place: false }) {
                self.show_window(ctx);
            }
            if let Some(command) = job_command(&finished) {
                self.send(ctx, command);
            }
            self.settings.apply(finished);
        }
        let menu = MenuModel::new(snapshot.clone());
        self.tray.update(&menu.entries(), &menu.status_line());
        // Drawn every frame: the window can be on screen before the tray ever asks for it, and an undrawn one is blank.
        self.draw_window(ctx, UiModel::new(snapshot), &menu.status_line());
        ctx.request_repaint_after(POLL_INTERVAL);
    }
}

fn header(ui: &mut egui::Ui, status: &str, needs_attention: bool) {
    ui.label(egui::RichText::new(crate::strings::TOOLTIP).size(26.0).strong().color(egui::Color32::WHITE));
    ui.horizontal(|ui| {
        theme::status_dot(ui, if needs_attention { theme::DANGER } else { theme::SUCCESS });
        ui.label(theme::muted(status));
    });
}

/// Hands a folder or a web address to Explorer, which opens it in the right program. Explorer reports a failure through an exit
/// code that is non-zero even on success, so only the start of the process is checked, and a failure to start is logged.
fn open_in_explorer(target: &str) {
    if let Err(error) = std::process::Command::new("explorer.exe").arg(target).spawn() {
        crate::logfile::record(&format!("could not open {target}: {error}"));
    }
}

/// What a tray choice does. It runs outside any frame, because the window may be hidden and then gets none.
fn tray_choice(handle: HostHandle, window: WindowControl) -> impl Fn(MenuAction) + Send + Sync + 'static {
    move |action| match action {
        // No frame will run to close the window, and nothing is left to save: settings are written as they change.
        MenuAction::Quit => std::process::exit(0),
        MenuAction::ShowPairingCode | MenuAction::ShowDevices | MenuAction::OpenSettings => window.show(),
        MenuAction::ToggleHosting => {
            let command = MenuModel::new(handle.snapshot()).command_for(action);
            if command.is_some_and(|command| !handle.send(command)) {
                std::process::exit(0);
            }
        }
    }
}

/// Shows the window each time a second launch is turned away, for as long as the app runs.
fn watch_show_requests(instance: &Arc<Guard>, window: &WindowControl) {
    let instance = Arc::clone(instance);
    let window = window.clone();
    let started = thread::Builder::new().name("show-requests".to_owned()).spawn(move || {
        while instance.wait_for_show_request() {
            window.show();
        }
    });
    if let Err(error) = started {
        crate::logfile::record(&format!("could not watch for a second launch: {error}"));
    }
}

fn program_path() -> std::io::Result<PathBuf> {
    std::env::current_exe()
}

impl HostApp {
    fn quit(&self, ctx: &egui::Context) {
        self.quitting.set(true);
        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
    }

    fn show_window(&mut self, ctx: &egui::Context) {
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
    }

    fn hide_window(&mut self, ctx: &egui::Context) {
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
    }

    fn draw_window(&mut self, ctx: &egui::Context, model: UiModel, status: &str) {
        let mut commands = Vec::new();
        let mut choices = Vec::new();
        let now_unix = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs());
        let panel = model.settings(&self.settings);
        let port = model.port();
        let page = egui::Frame::new().fill(theme::BACKDROP).inner_margin(egui::Margin::same(20));
        egui::CentralPanel::default().frame(page).show(ctx, |ui| {
            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                header(ui, status, !model.problems().is_empty());
                settings_view::firewall_prompt(ui, &panel, &mut choices);
                for problem in model.problems() {
                    theme::card(ui, |ui| {
                        ui.label(egui::RichText::new(problem).color(theme::DANGER));
                    });
                }
                pairing::show(ui, &model, now_unix, &mut self.reset_asked, &mut commands);
                settings_view::show(ui, &panel, &mut choices);
            });
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
            SettingsChoice::OpenLogs => {
                if let Some(folder) = crate::logfile::directory() {
                    open_in_explorer(&folder.to_string_lossy());
                }
            }
            SettingsChoice::OpenUpdatePage(page) => open_in_explorer(page),
            SettingsChoice::FrameRate(_)
            | SettingsChoice::RelayEnabled(_)
            | SettingsChoice::TerminalHooks(_)
            | SettingsChoice::CheckForUpdates(_) => {
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
            Ok(path) => {
                let result = firewall::request_rule_elevated(&path, port);
                if result.failure_reason().is_none() {
                    firewall::record_rule_applied(&path, port);
                }
                SettingsJob::Firewall(result)
            }
            Err(error) => SettingsJob::Firewall(firewall::HelperResult::CouldNotStart(error.to_string())),
        });
        if let Err(error) = started {
            self.settings.apply(SettingsJob::Firewall(firewall::HelperResult::CouldNotStart(error.to_string())));
        }
    }

    fn send(&self, ctx: &egui::Context, command: RuntimeCommand) {
        // The runtime has stopped, so nothing can answer the request: the application closes instead.
        if !self.handle.send(command) {
            self.quit(ctx);
        }
    }
}
