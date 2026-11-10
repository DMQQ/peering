//! Shows the window straight through Win32. egui applies its own show command during a frame, and Windows never repaints
//! a hidden window, so from the tray or a second launch that command never ran.

use eframe::egui;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::{SetForegroundWindow, ShowWindow, SW_SHOW};

#[derive(Clone)]
pub struct WindowControl {
    /// The window's HWND as a number, so the control can be sent to the tray's and the show request's threads.
    hwnd: Option<isize>,
    ctx: egui::Context,
}

impl WindowControl {
    pub fn of(creation: &eframe::CreationContext<'_>) -> Self {
        let hwnd = creation.window_handle().ok().and_then(|handle| match handle.as_raw() {
            RawWindowHandle::Win32(win32) => Some(win32.hwnd.get()),
            _ => None,
        });
        Self { hwnd, ctx: creation.egui_ctx.clone() }
    }

    pub fn show(&self) {
        if let Some(hwnd) = self.hwnd {
            // SAFETY: the HWND is the app's own window, which lives as long as the process.
            unsafe {
                let window = HWND(hwnd as *mut core::ffi::c_void);
                let _was_visible = ShowWindow(window, SW_SHOW);
                let _foreground = SetForegroundWindow(window);
            }
        }
        self.ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        self.ctx.request_repaint();
    }
}
