//! Monitor enumeration. The mapping from OS readings to `DisplayInfo` is pure; `monitors/sys.rs` reads the OS.

use peering_core::ports::capture::DisplayInfo;

#[cfg(windows)]
mod sys;

pub(crate) const BASE_DPI: u32 = 96;

/// One attached display as the OS reports it, before it is mapped to a `DisplayInfo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MonitorReading {
    /// The GDI device name, such as `\\.\DISPLAY1`.
    pub device_name: String,
    pub adapter_name: Option<String>,
    /// Top-left corner in the virtual desktop, in device pixels.
    pub origin_px: (i32, i32),
    pub size_px: (u32, u32),
    pub dpi: u32,
    pub is_primary: bool,
}

/// Stable across reboots and moves: the id comes from the device name alone, so a monitor keeps its id when it is
/// rearranged. Device names compare case-insensitively, so the hash folds case.
pub fn stable_display_id(device_name: &str) -> u32 {
    const OFFSET_BASIS: u32 = 0x811c_9dc5;
    const PRIME: u32 = 0x0100_0193;
    device_name
        .bytes()
        .map(|byte| byte.to_ascii_uppercase())
        .fold(OFFSET_BASIS, |hash, byte| (hash ^ u32::from(byte)).wrapping_mul(PRIME))
}

pub fn display_name(device_name: &str, adapter_name: Option<&str>) -> String {
    let number_start = device_name.trim_end_matches(|c: char| c.is_ascii_digit()).len();
    let digits = &device_name[number_start..];
    let base = if digits.is_empty() { device_name.to_string() } else { format!("Display {digits}") };
    match adapter_name.filter(|name| !name.is_empty()) {
        Some(adapter) => format!("{base} ({adapter})"),
        None => base,
    }
}

pub fn scale_for_dpi(dpi: u32) -> f64 {
    if dpi == 0 { 1.0 } else { f64::from(dpi) / f64::from(BASE_DPI) }
}

pub fn display_info(reading: &MonitorReading) -> DisplayInfo {
    let scale = scale_for_dpi(reading.dpi);
    DisplayInfo {
        id: stable_display_id(&reading.device_name),
        name: display_name(&reading.device_name, reading.adapter_name.as_deref()),
        pixel_width: reading.size_px.0,
        pixel_height: reading.size_px.1,
        origin_x: to_points(reading.origin_px.0, scale),
        origin_y: to_points(reading.origin_px.1, scale),
        scale,
        is_primary: reading.is_primary,
    }
}

/// The bounding box of every display in points, as (left, top, width, height).
pub fn virtual_desktop_rect(displays: &[DisplayInfo]) -> (i32, i32, u32, u32) {
    if displays.is_empty() {
        return (0, 0, 0, 0);
    }
    let left = displays.iter().map(|d| i64::from(d.origin_x)).min().unwrap_or(0);
    let top = displays.iter().map(|d| i64::from(d.origin_y)).min().unwrap_or(0);
    let right = displays.iter().map(|d| i64::from(d.origin_x) + points_width(d)).max().unwrap_or(left);
    let bottom = displays.iter().map(|d| i64::from(d.origin_y) + points_height(d)).max().unwrap_or(top);
    (clamp_to_i32(left), clamp_to_i32(top), clamp_to_u32(right - left), clamp_to_u32(bottom - top))
}

#[cfg(windows)]
pub fn enumerate_monitors() -> Vec<DisplayInfo> {
    enumerate_readings().iter().map(display_info).collect()
}

#[cfg(windows)]
pub fn enumerate_readings() -> Vec<MonitorReading> {
    sys::read_monitors()
}

pub(crate) fn to_points(pixels: i32, scale: f64) -> i32 {
    clamp_to_i32((f64::from(pixels) / scale).round() as i64)
}

fn points_width(display: &DisplayInfo) -> i64 {
    (f64::from(display.pixel_width) / effective_scale(display.scale)).round() as i64
}

fn points_height(display: &DisplayInfo) -> i64 {
    (f64::from(display.pixel_height) / effective_scale(display.scale)).round() as i64
}

fn effective_scale(scale: f64) -> f64 {
    if scale > 0.0 { scale } else { 1.0 }
}

fn clamp_to_i32(value: i64) -> i32 {
    value.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

fn clamp_to_u32(value: i64) -> u32 {
    value.clamp(0, i64::from(u32::MAX)) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(device_name: &str, origin_px: (i32, i32), size_px: (u32, u32), dpi: u32) -> MonitorReading {
        MonitorReading {
            device_name: device_name.to_string(),
            adapter_name: Some("Test Adapter".to_string()),
            origin_px,
            size_px,
            dpi,
            is_primary: false,
        }
    }

    fn display(origin_x: i32, origin_y: i32, pixel_width: u32, pixel_height: u32, scale: f64) -> DisplayInfo {
        DisplayInfo {
            id: 1,
            name: String::new(),
            pixel_width,
            pixel_height,
            origin_x,
            origin_y,
            scale,
            is_primary: false,
        }
    }

    #[test]
    fn the_same_device_name_keeps_its_id_wherever_the_monitor_sits() {
        let before = display_info(&reading(r"\\.\DISPLAY2", (0, 0), (1920, 1080), 96));
        let after = display_info(&reading(r"\\.\DISPLAY2", (-2560, 300), (1920, 1080), 96));
        assert_eq!(before.id, after.id);
    }

    #[test]
    fn different_device_names_get_different_ids() {
        assert_ne!(stable_display_id(r"\\.\DISPLAY1"), stable_display_id(r"\\.\DISPLAY2"));
    }

    #[test]
    fn device_name_case_does_not_change_the_id() {
        assert_eq!(stable_display_id(r"\\.\display1"), stable_display_id(r"\\.\DISPLAY1"));
    }

    #[test]
    fn the_id_is_fnv1a_over_the_uppercased_name() {
        assert_eq!(stable_display_id(""), 0x811c_9dc5);
        assert_eq!(stable_display_id("a"), 0xc40b_f6cc);
        assert_eq!(stable_display_id("DISPLAY1"), 0xe87f_a84c);
    }

    #[test]
    fn name_uses_the_monitor_number_and_adapter() {
        assert_eq!(display_name(r"\\.\DISPLAY3", Some("NVIDIA RTX")), "Display 3 (NVIDIA RTX)");
        assert_eq!(display_name(r"\\.\DISPLAY3", None), "Display 3");
        assert_eq!(display_name(r"\\.\DISPLAY3", Some("")), "Display 3");
    }

    #[test]
    fn name_falls_back_to_the_device_name_without_a_number() {
        assert_eq!(display_name("Monitor", None), "Monitor");
    }

    #[test]
    fn dpi_144_is_a_scale_of_one_and_a_half() {
        assert_eq!(scale_for_dpi(144), 1.5);
        assert_eq!(scale_for_dpi(96), 1.0);
        assert_eq!(scale_for_dpi(0), 1.0);
    }

    #[test]
    fn origin_is_reported_in_points_and_size_in_pixels() {
        let info = display_info(&reading(r"\\.\DISPLAY1", (3840, -1080), (3840, 2160), 192));
        assert_eq!(info.origin_x, 1920);
        assert_eq!(info.origin_y, -540);
        assert_eq!(info.pixel_width, 3840);
        assert_eq!(info.pixel_height, 2160);
        assert_eq!(info.scale, 2.0);
    }

    #[test]
    fn primary_flag_is_carried_through() {
        let mut primary = reading(r"\\.\DISPLAY1", (0, 0), (1920, 1080), 96);
        primary.is_primary = true;
        assert!(display_info(&primary).is_primary);
    }

    #[test]
    fn virtual_rect_of_no_displays_is_empty() {
        assert_eq!(virtual_desktop_rect(&[]), (0, 0, 0, 0));
    }

    #[test]
    fn virtual_rect_spans_a_monitor_left_of_the_primary() {
        let displays = [display(0, 0, 1920, 1080, 1.0), display(-1280, -200, 1280, 1024, 1.0)];
        assert_eq!(virtual_desktop_rect(&displays), (-1280, -200, 3200, 1280));
    }

    #[test]
    fn virtual_rect_uses_points_so_mixed_scales_line_up() {
        let displays = [display(0, 0, 3840, 2160, 2.0), display(1920, 0, 1920, 1080, 1.0)];
        assert_eq!(virtual_desktop_rect(&displays), (0, 0, 3840, 1080));
    }
}
