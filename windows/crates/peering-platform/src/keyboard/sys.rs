//! Windows side of the keyboard injector: converts key specs to `KEYBDINPUT` and calls `SendInput`.

use super::{KeyEventSpec, KeyInput};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP,
    KEYEVENTF_SCANCODE, KEYEVENTF_UNICODE, VIRTUAL_KEY,
};

pub(super) fn send(events: &[KeyEventSpec]) {
    if events.is_empty() {
        return;
    }
    let inputs: Vec<INPUT> = events.iter().map(to_input).collect();
    // SAFETY: each INPUT is fully initialised and the size passed is size_of::<INPUT>(), as SendInput requires.
    // A short count means UIPI or the secure desktop refused an event; InputSink has no error channel, so it is dropped.
    let _accepted = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
}

fn to_input(event: &KeyEventSpec) -> INPUT {
    let (scan, flags) = match event.input {
        KeyInput::Scancode(target) => {
            let extended = if target.extended { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
            (target.scancode, KEYEVENTF_SCANCODE | extended)
        }
        KeyInput::Unicode(unit) => (unit, KEYEVENTF_UNICODE),
    };
    let up = if event.key_up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) };
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: VIRTUAL_KEY(0), wScan: scan, dwFlags: flags | up, time: 0, dwExtraInfo: 0 },
        },
    }
}
