//! The cover windows. Unverified: written against the `windows` 0.58 API and not run on Windows.
//!
//! The windows belong to a thread of their own with a message loop, because a window answers messages only on the thread
//! that made it. `WM_DISPLAYCHANGE` reaches every top-level window, and is turned into one re-layout on that thread.

use std::collections::HashMap;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use peering_core::ports::curtain::{CoverReport, PrivacyCurtain};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{GetStockObject, BLACK_BRUSH, HBRUSH};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW, PeekMessageW, PostThreadMessageW,
    RegisterClassW, SetLayeredWindowAttributes, SetWindowDisplayAffinity, SetWindowPos, ShowWindow, HTTRANSPARENT,
    HWND_TOPMOST, LWA_ALPHA, MA_NOACTIVATE, MSG, PM_NOREMOVE, SWP_NOACTIVATE, SWP_SHOWWINDOW, SW_SHOWNOACTIVATE,
    WDA_EXCLUDEFROMCAPTURE, WM_APP, WM_DISPLAYCHANGE, WM_MOUSEACTIVATE, WM_NCHITTEST, WM_QUIT, WNDCLASSW,
    WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
};

use super::{plan, wanted_covers, CoverRect};
use crate::monitors::enumerate_readings;

const CLASS_NAME: PCWSTR = w!("PeeringPrivacyCurtain");
const RELAYOUT: u32 = WM_APP + 1;
const START_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Default)]
pub struct WindowsCurtain {
    running: Option<(u32, JoinHandle<()>)>,
}

impl PrivacyCurtain for WindowsCurtain {
    fn cover(&mut self) -> CoverReport {
        self.lift();
        let (started, report) = mpsc::channel();
        let handle = thread::spawn(move || run(&started));
        match report.recv_timeout(START_TIMEOUT) {
            Ok((thread_id, report)) => {
                self.running = Some((thread_id, handle));
                report
            }
            // A thread that never reported has made no window to leave behind.
            Err(_) => CoverReport::default(),
        }
    }

    fn lift(&mut self) {
        if let Some((thread_id, handle)) = self.running.take() {
            post(thread_id, WM_QUIT);
            let _joined = handle.join();
        }
    }
}

impl Drop for WindowsCurtain {
    fn drop(&mut self) {
        self.lift();
    }
}

fn post(thread_id: u32, message: u32) {
    // SAFETY: posts a message with no pointers to a thread id; a thread that has exited makes it fail harmlessly.
    let _posted = unsafe { PostThreadMessageW(thread_id, message, WPARAM(0), LPARAM(0)) };
}

fn run(started: &mpsc::Sender<(u32, CoverReport)>) {
    register_class();
    let mut message = MSG::default();
    // SAFETY: makes this thread's message queue exist before its id is handed out, so a posted quit is not lost.
    let _peeked = unsafe { PeekMessageW(&mut message, None, 0, 0, PM_NOREMOVE) };
    // SAFETY: takes no arguments.
    let thread_id = unsafe { GetCurrentThreadId() };
    let mut covers: HashMap<String, (HWND, CoverRect)> = HashMap::new();
    let report = relayout(&mut covers);
    if started.send((thread_id, report)).is_err() {
        close_all(&mut covers);
        return;
    }
    // SAFETY: `message` is a live MSG for every call; GetMessageW returns 0 for WM_QUIT and -1 on error, both of which end.
    while unsafe { GetMessageW(&mut message, None, 0, 0) }.0 > 0 {
        if message.hwnd.is_invalid() && message.message == RELAYOUT {
            relayout(&mut covers);
            continue;
        }
        // SAFETY: dispatching the message GetMessageW just filled in.
        unsafe { DispatchMessageW(&message) };
    }
    close_all(&mut covers);
}

fn register_class() {
    let class = WNDCLASSW {
        lpfnWndProc: Some(window_procedure),
        lpszClassName: CLASS_NAME,
        // SAFETY: a stock object is owned by the system and never freed.
        hbrBackground: HBRUSH(unsafe { GetStockObject(BLACK_BRUSH) }.0),
        ..Default::default()
    };
    // SAFETY: `class` is fully initialised; registering a class twice fails harmlessly and the first one is used.
    let _atom = unsafe { RegisterClassW(&class) };
}

fn relayout(covers: &mut HashMap<String, (HWND, CoverRect)>) -> CoverReport {
    let wanted = wanted_covers(&enumerate_readings());
    let current: Vec<(String, CoverRect)> = covers.iter().map(|(name, (_, rect))| (name.clone(), *rect)).collect();
    let planned = plan(&current, &wanted);
    for name in planned.close {
        if let Some((window, _)) = covers.remove(&name) {
            destroy(window);
        }
    }
    for (name, rect) in planned.resize {
        if let Some((window, up)) = covers.get_mut(&name) {
            place(*window, rect);
            *up = rect;
        }
    }
    let mut refused = 0;
    for (name, rect) in planned.open {
        match open(rect) {
            Some(window) => {
                covers.insert(name, (window, rect));
            }
            None => refused += 1,
        }
    }
    for (window, rect) in covers.values() {
        place(*window, *rect);
    }
    CoverReport { covered: covers.len(), refused }
}

/// `None` when the window could not be made or kept out of capture. A cover the capture sees would turn the phone's
/// picture black, so it is taken down rather than kept.
fn open(rect: CoverRect) -> Option<HWND> {
    let style = WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
    // SAFETY: the class is registered on this thread's process and every pointer argument is null or a static string.
    let window = unsafe {
        CreateWindowExW(style, CLASS_NAME, w!(""), WS_POPUP, rect.x, rect.y, rect.width, rect.height, None, None, None, None)
    }
    .ok()?;
    // SAFETY: `window` was made above on this thread.
    let kept_out = unsafe {
        SetLayeredWindowAttributes(window, COLORREF(0), 255, LWA_ALPHA).is_ok()
            && SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE).is_ok()
    };
    if !kept_out {
        destroy(window);
        return None;
    }
    // SAFETY: as above.
    let _shown = unsafe { ShowWindow(window, SW_SHOWNOACTIVATE) };
    Some(window)
}

fn place(window: HWND, rect: CoverRect) {
    // SAFETY: `window` is a cover this thread made and has not destroyed.
    let _placed = unsafe {
        SetWindowPos(window, HWND_TOPMOST, rect.x, rect.y, rect.width, rect.height, SWP_NOACTIVATE | SWP_SHOWWINDOW)
    };
}

fn destroy(window: HWND) {
    // SAFETY: `window` is a cover this thread made; it is forgotten after this.
    let _destroyed = unsafe { DestroyWindow(window) };
}

fn close_all(covers: &mut HashMap<String, (HWND, CoverRect)>) {
    for (_, (window, _)) in covers.drain() {
        destroy(window);
    }
}

/// Click-through and never activated: injected input follows the same hit test, so a cover that took clicks would
/// block the phone's clicks too.
unsafe extern "system" fn window_procedure(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        WM_DISPLAYCHANGE => {
            // SAFETY: takes no arguments; the re-layout runs on this same thread once the message loop sees it.
            post(unsafe { GetCurrentThreadId() }, RELAYOUT);
            LRESULT(0)
        }
        // SAFETY: the arguments are the ones this procedure was called with.
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
}
