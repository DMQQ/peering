//! Windows side of the mouse injector: screen metrics and `SendInput` for the specs the builders produce.

use super::{MouseEventSpec, VirtualDesktop};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEINPUT, MOUSE_EVENT_FLAGS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

pub(super) fn virtual_desktop() -> VirtualDesktop {
    // SAFETY: GetSystemMetrics reads no memory; the indices are fixed constants.
    unsafe {
        VirtualDesktop {
            left: GetSystemMetrics(SM_XVIRTUALSCREEN),
            top: GetSystemMetrics(SM_YVIRTUALSCREEN),
            width: GetSystemMetrics(SM_CXVIRTUALSCREEN),
            height: GetSystemMetrics(SM_CYVIRTUALSCREEN),
        }
    }
}

pub(super) fn send(events: &[MouseEventSpec]) {
    if events.is_empty() {
        return;
    }
    let inputs: Vec<INPUT> = events.iter().map(to_input).collect();
    // SAFETY: each INPUT is fully initialised and the size passed is size_of::<INPUT>(), as SendInput requires.
    // A short count means UIPI or the secure desktop refused an event; InputSink has no error channel, so it is dropped.
    let _accepted = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
}

fn to_input(event: &MouseEventSpec) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: event.dx,
                dy: event.dy,
                mouseData: event.data as u32,
                dwFlags: MOUSE_EVENT_FLAGS(event.flags.0),
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}
