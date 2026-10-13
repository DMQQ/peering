//! UI Automation calls for the focus watcher. Unverified: written against the `windows` 0.58 API and not run on Windows.
//!
//! One thread owns the automation object and does every call, so a program that has stopped answering costs that thread
//! some seconds and nothing else. It looks at the focus every 300 ms while watching, as the Mac host does, and answers a tap
//! 150 ms after it was asked about, which is long enough for the click to have moved the focus.

use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use peering_core::ports::focus::{FocusProbe, FocusReport, FocusSnapshot};
use windows::Win32::Foundation::{CloseHandle, POINT};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, SAFEARRAY,
};
use windows::Win32::System::Ole::{SafeArrayAccessData, SafeArrayDestroy, SafeArrayGetLBound, SafeArrayGetUBound, SafeArrayUnaccessData};
use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationTextPattern, IUIAutomationTextRange, IUIAutomationValuePattern,
    TextPatternRangeEndpoint_End, TextPatternRangeEndpoint_Start, UIA_TextPatternId, UIA_ValuePatternId,
};

use super::{caret_point, is_terminal_program, takes_typing, utf16_length_within, ElementTraits};

const LOOK_EVERY: Duration = Duration::from_millis(300);
const TAP_DELAY: Duration = Duration::from_millis(150);
/// Text past this is not read: the host sends no field this long, and asking for all of a long document is slow.
const READ_LIMIT: usize = 8000;

enum Command {
    Tap { x: i32, y: i32, at: Instant },
    Stop,
}

#[derive(Default)]
struct Shared {
    reports: Mutex<Vec<FocusReport>>,
}

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Worker {
    commands: Sender<Command>,
    thread: JoinHandle<()>,
}

#[derive(Default)]
pub struct UiaFocus {
    shared: Arc<Shared>,
    worker: Option<Worker>,
}

impl FocusProbe for UiaFocus {
    fn set_active(&mut self, active: bool) {
        match (active, self.worker.is_some()) {
            (true, false) => {
                locked(&self.shared.reports).clear();
                let (commands, inbox) = channel();
                let shared = self.shared.clone();
                let thread = thread::spawn(move || watch(&shared, &inbox));
                self.worker = Some(Worker { commands, thread });
            }
            (false, true) => self.stop(),
            _ => {}
        }
    }

    fn tapped_at(&mut self, x: i32, y: i32) {
        if let Some(worker) = &self.worker {
            // A worker that has ended takes no more taps, which only means the answer never comes.
            let _sent = worker.commands.send(Command::Tap { x, y, at: Instant::now() + TAP_DELAY });
        }
    }

    fn drain(&mut self) -> Vec<FocusReport> {
        std::mem::take(&mut *locked(&self.shared.reports))
    }
}

impl UiaFocus {
    fn stop(&mut self) {
        if let Some(worker) = self.worker.take() {
            let _sent = worker.commands.send(Command::Stop);
            // The thread may be inside a call to a program that has stopped answering; it ends when that call does.
            drop(worker.thread);
        }
        locked(&self.shared.reports).clear();
    }
}

impl Drop for UiaFocus {
    fn drop(&mut self) {
        self.stop();
    }
}

struct ComGuard(bool);

impl Drop for ComGuard {
    fn drop(&mut self) {
        if self.0 {
            // SAFETY: balances the successful `CoInitializeEx` on this same thread.
            unsafe { CoUninitialize() };
        }
    }
}

fn watch(shared: &Shared, inbox: &std::sync::mpsc::Receiver<Command>) {
    // SAFETY: called once on this thread, and balanced by the guard.
    let _com = ComGuard(unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok());
    // SAFETY: COM is initialised for this thread; the automation object is used only here.
    let Ok(automation) = (unsafe { CoCreateInstance::<_, IUIAutomation>(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }) else {
        return;
    };
    let mut state = Watching { automation, previous: None, element_number: 0, last: None };
    let mut next_look = Instant::now();
    let mut taps: Vec<(i32, i32, Instant)> = Vec::new();
    loop {
        let wait = taps.iter().map(|tap| tap.2).chain([next_look]).min().map_or(LOOK_EVERY, |due| due.saturating_duration_since(Instant::now()));
        match inbox.recv_timeout(wait) {
            Ok(Command::Stop) | Err(RecvTimeoutError::Disconnected) => return,
            Ok(Command::Tap { x, y, at }) => taps.push((x, y, at)),
            Err(RecvTimeoutError::Timeout) => {}
        }
        let now = Instant::now();
        let (due, waiting): (Vec<_>, Vec<_>) = taps.into_iter().partition(|tap| tap.2 <= now);
        taps = waiting;
        for (x, y, _) in due {
            let editable = state.editable_at(x, y);
            locked(&shared.reports).push(FocusReport::Tapped { editable });
        }
        if now >= next_look {
            next_look = now + LOOK_EVERY;
            if let Some(report) = state.look() {
                locked(&shared.reports).push(report);
            }
        }
    }
}

struct Watching {
    automation: IUIAutomation,
    previous: Option<IUIAutomationElement>,
    element_number: u64,
    last: Option<Option<FocusSnapshot>>,
}

impl Watching {
    /// What the focus is now, or `None` when it is what it was at the last look.
    fn look(&mut self) -> Option<FocusReport> {
        // SAFETY: a plain COM call on the automation object this thread owns.
        let focused = unsafe { self.automation.GetFocusedElement() }.ok();
        let snapshot = focused.map(|element| self.snapshot(element));
        if self.last.as_ref() == Some(&snapshot) {
            return None;
        }
        self.last = Some(snapshot.clone());
        Some(FocusReport::Focus(snapshot))
    }

    fn snapshot(&mut self, element: IUIAutomationElement) -> FocusSnapshot {
        let same = self.previous.as_ref().is_some_and(|previous| {
            // SAFETY: both are live elements of the automation object.
            unsafe { self.automation.CompareElements(previous, &element) }.is_ok_and(|same| same.as_bool())
        });
        if !same {
            self.element_number += 1;
        }
        self.previous = Some(element.clone());
        let traits = element_traits(&element);
        let editable = takes_typing(traits);
        let mut snapshot = FocusSnapshot {
            element: self.element_number,
            editable,
            secure: false,
            terminal: false,
            text: None,
            selection: None,
            caret: None,
        };
        if editable {
            read_field(&element, &mut snapshot);
        }
        snapshot
    }

    fn editable_at(&mut self, x: i32, y: i32) -> bool {
        // SAFETY: a plain COM call on the automation object this thread owns.
        match unsafe { self.automation.ElementFromPoint(POINT { x, y }) } {
            Ok(element) => takes_typing(element_traits(&element)),
            Err(_) => false,
        }
    }
}

fn element_traits(element: &IUIAutomationElement) -> ElementTraits {
    // SAFETY: plain COM calls on a live element. A call that fails reads as an element with nothing to offer.
    unsafe {
        let control_type = element.CurrentControlType().map_or(0, |kind| kind.0);
        let value_read_only = element
            .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
            .ok()
            .and_then(|pattern| pattern.CurrentIsReadOnly().ok())
            .map(|read_only| read_only.as_bool());
        ElementTraits { control_type, value_read_only }
    }
}

fn read_field(element: &IUIAutomationElement, snapshot: &mut FocusSnapshot) {
    // SAFETY: plain COM calls on a live element.
    unsafe {
        snapshot.secure = element.CurrentIsPassword().is_ok_and(|secure| secure.as_bool());
        snapshot.terminal = element.CurrentProcessId().ok().and_then(process_image).is_some_and(|image| is_terminal_program(&image));
        let element_rectangle = element.CurrentBoundingRectangle().ok().map(|rectangle| {
            [
                f64::from(rectangle.left),
                f64::from(rectangle.top),
                f64::from(rectangle.right - rectangle.left),
                f64::from(rectangle.bottom - rectangle.top),
            ]
        });
        let mut text_rectangles = Vec::new();
        if !snapshot.secure && !snapshot.terminal {
            snapshot.text = element
                .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                .ok()
                .and_then(|pattern| pattern.CurrentValue().ok())
                .map(|value| value.to_string());
        }
        if let Ok(pattern) = element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) {
            let selection = selection_of(&pattern);
            if let Some((location, length, rectangles)) = selection {
                snapshot.selection = Some((location, length));
                text_rectangles = rectangles;
            }
            if snapshot.text.is_none() && !snapshot.secure && !snapshot.terminal {
                snapshot.text = pattern.DocumentRange().ok().and_then(|range| range.GetText(READ_LIMIT as i32 + 1).ok()).map(|text| text.to_string());
            }
        }
        snapshot.caret = if snapshot.secure { None } else { caret_point(&text_rectangles, element_rectangle) };
    }
}

/// Where the selection starts and how long it is in UTF-16 units, and the rectangles it covers.
///
/// # Safety
/// `pattern` must belong to a live element.
unsafe fn selection_of(pattern: &IUIAutomationTextPattern) -> Option<(u32, u32, Vec<f64>)> {
    let ranges = pattern.GetSelection().ok()?;
    if ranges.Length().ok()? < 1 {
        return None;
    }
    let selected: IUIAutomationTextRange = ranges.GetElement(0).ok()?;
    let length = utf16_length_within(&selected.GetText(READ_LIMIT as i32 + 1).ok()?.to_string(), READ_LIMIT)?;
    let before = pattern.DocumentRange().ok()?.Clone().ok()?;
    before.MoveEndpointByRange(TextPatternRangeEndpoint_End, &selected, TextPatternRangeEndpoint_Start).ok()?;
    let location = utf16_length_within(&before.GetText(READ_LIMIT as i32 + 1).ok()?.to_string(), READ_LIMIT)?;
    let rectangles = selected.GetBoundingRectangles().ok().map(|array| doubles_of(array)).unwrap_or_default();
    Some((location, length, rectangles))
}

/// Reads and frees a SAFEARRAY of doubles.
///
/// # Safety
/// `array` must be a SAFEARRAY of doubles returned by UI Automation, which the caller owns.
unsafe fn doubles_of(array: *mut SAFEARRAY) -> Vec<f64> {
    if array.is_null() {
        return Vec::new();
    }
    let mut values = Vec::new();
    if let (Ok(low), Ok(high)) = (SafeArrayGetLBound(array, 1), SafeArrayGetUBound(array, 1)) {
        let mut data: *mut std::ffi::c_void = std::ptr::null_mut();
        if high >= low && SafeArrayAccessData(array, &mut data).is_ok() && !data.is_null() {
            let count = (high - low + 1) as usize;
            values = std::slice::from_raw_parts(data.cast::<f64>(), count).to_vec();
            let _unlocked = SafeArrayUnaccessData(array);
        }
    }
    let _freed = SafeArrayDestroy(array);
    values
}

fn process_image(process_id: i32) -> Option<String> {
    // SAFETY: the handle is closed before returning, and the buffer is as long as the length passed with it.
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, u32::try_from(process_id).ok()?).ok()?;
        let mut buffer = [0u16; 520];
        let mut length = buffer.len() as u32;
        let queried = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buffer.as_mut_ptr()), &mut length);
        let _closed = CloseHandle(process);
        queried.ok()?;
        Some(String::from_utf16_lossy(&buffer[..length as usize]))
    }
}
