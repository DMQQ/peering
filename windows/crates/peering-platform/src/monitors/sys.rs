//! GDI and per-monitor DPI calls behind `monitors::enumerate_monitors`.

use std::mem::size_of;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{BOOL, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayDevicesW, EnumDisplayMonitors, EnumDisplaySettingsW, GetMonitorInfoW, DEVMODEW, DISPLAY_DEVICEW,
    ENUM_CURRENT_SETTINGS, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW,
};
use windows::Win32::UI::WindowsAndMessaging::MONITORINFOF_PRIMARY;
use windows::Win32::UI::HiDpi::{
    GetDpiForMonitor, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI,
};

use crate::monitors::{MonitorReading, BASE_DPI};

const MAX_ADAPTERS: u32 = 64;

pub fn read_monitors() -> Vec<MonitorReading> {
    prefer_per_monitor_dpi();
    let mut handles: Vec<HMONITOR> = Vec::new();
    // SAFETY: the callback runs synchronously inside this call and only touches `handles`, which lives until it returns.
    unsafe {
        let _ = EnumDisplayMonitors(
            None,
            None,
            Some(collect_monitor),
            LPARAM(&mut handles as *mut Vec<HMONITOR> as isize),
        );
    }
    handles.into_iter().filter_map(reading_for).collect()
}

/// GetMonitorInfo and EnumDisplaySettings disagree on coordinates unless the process is DPI aware. The call fails
/// harmlessly when the host already set awareness, so its result is ignored.
fn prefer_per_monitor_dpi() {
    // SAFETY: sets a process-wide flag and takes no pointers.
    let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
}

unsafe extern "system" fn collect_monitor(monitor: HMONITOR, _hdc: HDC, _rect: *mut RECT, data: LPARAM) -> BOOL {
    // SAFETY: `data` is the `&mut Vec<HMONITOR>` passed by `read_monitors`, valid for this synchronous callback.
    let handles = unsafe { &mut *(data.0 as *mut Vec<HMONITOR>) };
    handles.push(monitor);
    BOOL::from(true)
}

fn reading_for(monitor: HMONITOR) -> Option<MonitorReading> {
    let info = monitor_info(monitor)?;
    let device_name = wide_to_string(&info.szDevice);
    let rect = info.monitorInfo.rcMonitor;
    let size_px = display_size(&info.szDevice).unwrap_or_else(|| {
        (rect.right.saturating_sub(rect.left).max(0) as u32, rect.bottom.saturating_sub(rect.top).max(0) as u32)
    });
    Some(MonitorReading {
        adapter_name: adapter_name(&device_name),
        device_name,
        origin_px: (rect.left, rect.top),
        size_px,
        dpi: effective_dpi(monitor),
        is_primary: info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0,
    })
}

fn monitor_info(monitor: HMONITOR) -> Option<MONITORINFOEXW> {
    // SAFETY: MONITORINFOEXW is plain data, so an all-zero value is valid before cbSize is set below.
    let mut info: MONITORINFOEXW = unsafe { std::mem::zeroed() };
    info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    // SAFETY: `info` is a MONITORINFOEXW with cbSize set, which GetMonitorInfoW reads through a MONITORINFO pointer.
    let ok = unsafe { GetMonitorInfoW(monitor, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) };
    ok.as_bool().then_some(info)
}

fn display_size(device: &[u16; 32]) -> Option<(u32, u32)> {
    // SAFETY: DEVMODEW is plain data; dmSize is set before the call, as EnumDisplaySettingsW expects.
    let mut mode: DEVMODEW = unsafe { std::mem::zeroed() };
    mode.dmSize = size_of::<DEVMODEW>() as u16;
    // SAFETY: `device` is a NUL-terminated device name owned by the caller, and `mode` is writable for its full size.
    let ok = unsafe { EnumDisplaySettingsW(PCWSTR(device.as_ptr()), ENUM_CURRENT_SETTINGS, &mut mode) };
    ok.as_bool().then_some((mode.dmPelsWidth, mode.dmPelsHeight))
}

fn effective_dpi(monitor: HMONITOR) -> u32 {
    let (mut dpi_x, mut dpi_y) = (0u32, 0u32);
    // SAFETY: both out pointers refer to live locals for the duration of the call.
    let result = unsafe { GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) };
    match result {
        Ok(()) if dpi_x > 0 => dpi_x,
        _ => BASE_DPI,
    }
}

fn adapter_name(device_name: &str) -> Option<String> {
    for index in 0..MAX_ADAPTERS {
        // SAFETY: DISPLAY_DEVICEW is plain data; cb is set before the call, as EnumDisplayDevicesW requires.
        let mut adapter: DISPLAY_DEVICEW = unsafe { std::mem::zeroed() };
        adapter.cb = size_of::<DISPLAY_DEVICEW>() as u32;
        // SAFETY: a null device name lists adapters, and `adapter` is writable for its full size.
        let ok = unsafe { EnumDisplayDevicesW(PCWSTR::null(), index, &mut adapter, 0) };
        if !ok.as_bool() {
            return None;
        }
        if wide_to_string(&adapter.DeviceName).eq_ignore_ascii_case(device_name) {
            return Some(wide_to_string(&adapter.DeviceString));
        }
    }
    None
}

fn wide_to_string(wide: &[u16]) -> String {
    let end = wide.iter().position(|&unit| unit == 0).unwrap_or(wide.len());
    String::from_utf16_lossy(&wide[..end])
}
