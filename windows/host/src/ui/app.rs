//! The application that owns the tray and the window. Windows only, and unverified: it is written against the eframe
//! 0.31 and tray-icon APIs and has not been run on Windows. The window starts hidden; the tray is the entry point, and
//! closing the window hides it again rather than quitting.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use eframe::egui;

use super::model::{MenuAction, MenuModel, UiModel};
use super::pairing;
use super::tray::Tray;
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
            Ok(Box::new(HostApp { handle, tray, window_open: false }))
        }),
    )
}

struct HostApp {
    handle: HostHandle,
    tray: Tray,
    window_open: bool,
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

impl HostApp {
    fn choose(&mut self, ctx: &egui::Context, menu: &MenuModel, action: MenuAction) {
        match action {
            MenuAction::Quit => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            MenuAction::ShowPairingCode | MenuAction::ShowDevices => self.show_window(ctx),
            MenuAction::ToggleHosting | MenuAction::OpenSettings => {
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
        let now_unix = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs());
        egui::CentralPanel::default().show(ctx, |ui| {
            pairing::show(ui, &model, now_unix, &mut commands);
        });
        for command in commands {
            self.send(ctx, command);
        }
    }

    fn send(&self, ctx: &egui::Context, command: RuntimeCommand) {
        // The runtime has stopped, so nothing can answer the request: the application closes instead.
        if !self.handle.send(command) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }
}
