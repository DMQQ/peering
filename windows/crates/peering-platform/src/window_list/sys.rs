//! Reads the top-level windows and keeps those Windows.Graphics.Capture accepts. Unverified: written against the `windows` 0.58
//! API and not run on Windows.

use windows::core::PWSTR;
use windows::Graphics::Capture::{GraphicsCaptureItem, GraphicsCaptureSession};
use windows::Win32::Foundation::{CloseHandle, BOOL, HWND, LPARAM, RECT};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::System::Threading::{
    GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetWindow, GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsIconic,
    IsWindow, IsWindowVisible, GWL_EXSTYLE, GW_OWNER, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW,
};

use super::{window_info, RawWindow};
use peering_core::ports::capture::WindowInfo;

/// Every window worth offering that can be captured now. Empty where Windows.Graphics.Capture is not available.
pub fn capturable_windows() -> Vec<WindowInfo> {
    if !GraphicsCaptureSession::IsSupported().unwrap_or(false) {
        return Vec::new();
    }
    let mut handles: Vec<HWND> = Vec::new();
    // SAFETY: the callback runs synchronously inside this call and only touches `handles`, which lives until it returns.
    let _enumerated = unsafe { EnumWindows(Some(collect), LPARAM(&mut handles as *mut Vec<HWND> as isize)) };
    handles.into_iter().filter_map(|handle| info_for(handle).filter(|info| can_be_captured(info.id))).collect()
}

/// One window by its handle, if it is still one to offer. Cheap enough to ask many times a second, unlike the list.
pub fn window_rectangle(id: u32) -> Option<WindowInfo> {
    info_for(HWND(id as isize as *mut core::ffi::c_void))
}

unsafe extern "system" fn collect(window: HWND, data: LPARAM) -> BOOL {
    // SAFETY: `data` is the `&mut Vec<HWND>` passed by `capturable_windows`, valid for this synchronous callback.
    let handles = unsafe { &mut *(data.0 as *mut Vec<HWND>) };
    handles.push(window);
    BOOL::from(true)
}

fn info_for(window: HWND) -> Option<WindowInfo> {
    // SAFETY: plain queries on a window handle, which at worst no longer names a window.
    unsafe {
        if !IsWindow(window).as_bool() {
            return None;
        }
        let style = GetWindowLongPtrW(window, GWL_EXSTYLE) as u32;
        let frame = frame_of(window)?;
        let mut process_id = 0u32;
        GetWindowThreadProcessId(window, Some(&mut process_id));
        window_info(&RawWindow {
            handle: window.0 as usize as u32,
            title: title_of(window),
            class_name: class_of(window),
            program_path: program_of(process_id),
            visible: IsWindowVisible(window).as_bool(),
            minimized: IsIconic(window).as_bool(),
            cloaked: is_cloaked(window),
            has_owner: GetWindow(window, GW_OWNER).is_ok_and(|owner| !owner.0.is_null()),
            tool_window: style & WS_EX_TOOLWINDOW.0 != 0,
            app_window: style & WS_EX_APPWINDOW.0 != 0,
            belongs_to_this_program: process_id == GetCurrentProcessId(),
            origin_px: (frame.left, frame.top),
            size_px: (frame.right.saturating_sub(frame.left).max(0) as u32, frame.bottom.saturating_sub(frame.top).max(0) as u32),
            dpi: GetDpiForWindow(window),
        })
    }
}

/// The frame as the person sees it, without the invisible border Windows draws around a window for resizing.
unsafe fn frame_of(window: HWND) -> Option<RECT> {
    let mut frame = RECT::default();
    DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, (&mut frame as *mut RECT).cast(), std::mem::size_of::<RECT>() as u32).ok()?;
    Some(frame)
}

unsafe fn is_cloaked(window: HWND) -> bool {
    let mut cloaked = 0u32;
    DwmGetWindowAttribute(window, DWMWA_CLOAKED, (&mut cloaked as *mut u32).cast(), std::mem::size_of::<u32>() as u32).is_ok() && cloaked != 0
}

unsafe fn title_of(window: HWND) -> String {
    let length = GetWindowTextLengthW(window);
    if length <= 0 {
        return String::new();
    }
    let mut buffer = vec![0u16; length as usize + 1];
    let copied = GetWindowTextW(window, &mut buffer);
    String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
}

unsafe fn class_of(window: HWND) -> String {
    let mut buffer = [0u16; 256];
    let copied = GetClassNameW(window, &mut buffer);
    String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
}

unsafe fn program_of(process_id: u32) -> String {
    let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process_id) else {
        return String::new();
    };
    let mut buffer = [0u16; 520];
    let mut length = buffer.len() as u32;
    let queried = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut length);
    let _closed = CloseHandle(process);
    if queried.is_ok() { String::from_utf16_lossy(&buffer[..length as usize]) } else { String::new() }
}

/// Whether a capture item can be made for the window, which is the first thing starting a capture does.
fn can_be_captured(id: u32) -> bool {
    create_item(id).is_some()
}

pub(crate) fn create_item(id: u32) -> Option<GraphicsCaptureItem> {
    let interop = windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().ok()?;
    // SAFETY: `CreateForWindow` only reads the handle and fails for one that is not a window it can capture.
    unsafe { interop.CreateForWindow::<_, GraphicsCaptureItem>(HWND(id as usize as *mut core::ffi::c_void)) }.ok()
}
