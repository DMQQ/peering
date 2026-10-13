//! The windows a phone can choose to look at. Which windows count is decided here and tested on any OS; `window_list/sys.rs`
//! reads them from the operating system and keeps only those Windows.Graphics.Capture will take.

use peering_core::ports::capture::WindowInfo;

use crate::monitors::{scale_for_dpi, to_points};

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::{capturable_windows, window_rectangle};
#[cfg(windows)]
pub(crate) use sys::create_item;

/// Longest title kept; a longer one is cut with an ellipsis.
const MAXIMUM_TITLE_CHARACTERS: usize = 120;
/// Smaller than this on a side is a helper window, not something to look at.
const SMALLEST_SIDE: u32 = 64;

/// Classes of the desktop itself and its helpers, which have titles and sizes and are not windows to share.
const SHELL_CLASSES: [&str; 6] =
    ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland"];

/// One top-level window as the operating system reports it.
#[derive(Debug, Clone, PartialEq)]
pub struct RawWindow {
    pub handle: u32,
    pub title: String,
    pub class_name: String,
    /// Full path of the program's file, when it could be read.
    pub program_path: String,
    pub visible: bool,
    pub minimized: bool,
    /// Hidden by the shell, as a window of a suspended store app or one on another virtual desktop is.
    pub cloaked: bool,
    pub has_owner: bool,
    pub tool_window: bool,
    pub app_window: bool,
    pub belongs_to_this_program: bool,
    /// The visible frame, in desktop pixels.
    pub origin_px: (i32, i32),
    pub size_px: (u32, u32),
    pub dpi: u32,
}

/// The window as the catalogue lists it, or `None` when it is not one to offer.
pub fn window_info(raw: &RawWindow) -> Option<WindowInfo> {
    let title = raw.title.trim();
    let listed = raw.visible
        && !raw.minimized
        && !raw.cloaked
        && !title.is_empty()
        && (!raw.has_owner || raw.app_window)
        && (!raw.tool_window || raw.app_window)
        && !raw.belongs_to_this_program
        && !SHELL_CLASSES.contains(&raw.class_name.as_str())
        && raw.size_px.0 >= SMALLEST_SIDE
        && raw.size_px.1 >= SMALLEST_SIDE;
    if !listed {
        return None;
    }
    let scale = scale_for_dpi(raw.dpi);
    Some(WindowInfo {
        id: raw.handle,
        title: shortened(title),
        application: application_name(&raw.program_path),
        pixel_width: raw.size_px.0,
        pixel_height: raw.size_px.1,
        origin_x: to_points(raw.origin_px.0, scale),
        origin_y: to_points(raw.origin_px.1, scale),
        scale,
    })
}

/// The program's file name without its folder or extension, starting with a capital: `C:\Windows\notepad.exe` is "Notepad".
pub fn application_name(program_path: &str) -> String {
    let file = program_path.rsplit(['\\', '/']).next().unwrap_or(program_path);
    let stem = file.rsplit_once('.').map_or(file, |(stem, _)| stem);
    let mut letters = stem.chars();
    match letters.next() {
        Some(first) => first.to_uppercase().chain(letters).collect(),
        None => String::new(),
    }
}

fn shortened(title: &str) -> String {
    if title.chars().count() <= MAXIMUM_TITLE_CHARACTERS {
        return title.to_owned();
    }
    let cut: String = title.chars().take(MAXIMUM_TITLE_CHARACTERS - 1).collect();
    format!("{}\u{2026}", cut.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notepad() -> RawWindow {
        RawWindow {
            handle: 0x1234,
            title: "notes.txt - Notepad".to_owned(),
            class_name: "Notepad".to_owned(),
            program_path: "C:\\Windows\\System32\\notepad.exe".to_owned(),
            visible: true,
            minimized: false,
            cloaked: false,
            has_owner: false,
            tool_window: false,
            app_window: false,
            belongs_to_this_program: false,
            origin_px: (100, 50),
            size_px: (800, 600),
            dpi: 96,
        }
    }

    #[test]
    fn an_ordinary_window_is_listed_with_its_program_and_size() {
        let info = window_info(&notepad()).expect("a window to offer");
        assert_eq!(info.id, 0x1234);
        assert_eq!(info.title, "notes.txt - Notepad");
        assert_eq!(info.application, "Notepad");
        assert_eq!((info.pixel_width, info.pixel_height), (800, 600));
        assert_eq!((info.origin_x, info.origin_y, info.scale), (100, 50, 1.0));
    }

    #[test]
    fn the_corner_is_in_points_and_the_size_in_pixels_on_a_scaled_display() {
        let scaled = RawWindow { origin_px: (300, 150), dpi: 192, ..notepad() };
        let info = window_info(&scaled).expect("a window to offer");
        assert_eq!((info.origin_x, info.origin_y, info.scale), (150, 75, 2.0));
        assert_eq!((info.pixel_width, info.pixel_height), (800, 600));
    }

    #[test]
    fn what_cannot_be_seen_is_not_offered() {
        for hidden in [
            RawWindow { visible: false, ..notepad() },
            RawWindow { minimized: true, ..notepad() },
            RawWindow { cloaked: true, ..notepad() },
        ] {
            assert_eq!(window_info(&hidden), None);
        }
    }

    #[test]
    fn a_window_without_a_title_is_not_offered() {
        assert_eq!(window_info(&RawWindow { title: "   ".to_owned(), ..notepad() }), None);
    }

    #[test]
    fn dialogs_and_tool_windows_are_not_offered_unless_they_ask_to_be_in_the_task_bar() {
        assert_eq!(window_info(&RawWindow { has_owner: true, ..notepad() }), None);
        assert_eq!(window_info(&RawWindow { tool_window: true, ..notepad() }), None);
        assert!(window_info(&RawWindow { has_owner: true, app_window: true, ..notepad() }).is_some());
        assert!(window_info(&RawWindow { tool_window: true, app_window: true, ..notepad() }).is_some());
    }

    #[test]
    fn the_hosts_own_windows_and_the_desktop_are_not_offered() {
        assert_eq!(window_info(&RawWindow { belongs_to_this_program: true, ..notepad() }), None);
        for class_name in ["Progman", "WorkerW", "Shell_TrayWnd"] {
            assert_eq!(window_info(&RawWindow { class_name: class_name.to_owned(), ..notepad() }), None, "{class_name}");
        }
    }

    #[test]
    fn a_sliver_is_not_offered() {
        assert_eq!(window_info(&RawWindow { size_px: (800, 20), ..notepad() }), None);
        assert!(window_info(&RawWindow { size_px: (64, 64), ..notepad() }).is_some());
    }

    #[test]
    fn a_long_title_is_cut_with_an_ellipsis() {
        let info = window_info(&RawWindow { title: "x".repeat(300), ..notepad() }).expect("a window to offer");
        assert_eq!(info.title.chars().count(), 120);
        assert!(info.title.ends_with('\u{2026}'));
    }

    #[test]
    fn the_program_name_comes_from_the_file() {
        assert_eq!(application_name("C:\\Program Files\\Mozilla Firefox\\firefox.exe"), "Firefox");
        assert_eq!(application_name("C:/tools/Code.EXE"), "Code");
        assert_eq!(application_name("WindowsTerminal.exe"), "WindowsTerminal");
        assert_eq!(application_name(""), "");
    }
}
