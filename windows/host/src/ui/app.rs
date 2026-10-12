//! The application that owns the tray and the window. Windows only, and unverified: it is written against the eframe
//! 0.31 and tray-icon APIs and has not been run on Windows. The window is hidden; the tray is the entry point.

use std::time::Duration;

use eframe::egui;

use super::model::{MenuAction, MenuModel};
use super::tray::Tray;
use crate::runtime::HostHandle;

const POLL_INTERVAL: Duration = Duration::from_millis(250);

pub fn run(handle: HostHandle) -> Result<(), eframe::Error> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_visible(false).with_inner_size([420.0, 560.0]),
        ..Default::default()
    };
    eframe::run_native(
        crate::strings::TOOLTIP,
        options,
        Box::new(move |_creation| {
            let model = MenuModel::new(handle.snapshot());
            let tray = Tray::new(&model.entries())?;
            Ok(Box::new(HostApp { handle, tray }))
        }),
    )
}

struct HostApp {
    handle: HostHandle,
    tray: Tray,
}

impl eframe::App for HostApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let model = MenuModel::new(self.handle.snapshot());
        self.tray.update(&model.entries(), &model.status_line());
        while let Some(action) = self.tray.poll() {
            self.choose(ctx, &model, action);
        }
        ctx.request_repaint_after(POLL_INTERVAL);
    }
}

impl HostApp {
    fn choose(&self, ctx: &egui::Context, model: &MenuModel, action: MenuAction) {
        if action == MenuAction::Quit {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            return;
        }
        if let Some(command) = model.command_for(action) {
            // The runtime has stopped, so nothing can answer the choice: the application closes instead.
            if !self.handle.send(command) {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
    }
}
