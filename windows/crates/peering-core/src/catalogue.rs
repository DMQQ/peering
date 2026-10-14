//! The capture catalogue the host pushes to each session, built from the displays the capture port reports.

use std::collections::HashMap;
use std::hash::Hash;

use peering_wire::frame_budget::{longest_prefix, CONTROL_LIST_BUDGET};
use peering_wire::source::{CaptureCatalog, CaptureSourceDescriptor};

use crate::ports::capture::{DisplayInfo, WindowInfo};

/// "Display 1 (primary)" for the first display, "Display 2" for the next. The ordinal is the display's position
/// in the catalogue, not its platform id, so the phone's labels stay 1..n whatever the host's ids are.
pub fn display_title(ordinal: usize, is_primary: bool) -> String {
    if is_primary {
        format!("Display {ordinal} (primary)")
    } else {
        format!("Display {ordinal}")
    }
}

/// Builds the catalogue from the displays and reports only the catalogues that differ from the last one.
#[derive(Debug, Default)]
pub struct CatalogueService {
    current: Option<CaptureCatalog>,
    /// The thumbnail each source id was last photographed with, attached to its descriptor whenever the catalogue is built.
    pictures: HashMap<String, serde_json::Value>,
}

impl CatalogueService {
    pub fn new() -> Self {
        Self::default()
    }

    /// Keeps `picture` for the source `id`. Returns whether it differs from the one held, which means the catalogue changed.
    pub fn set_picture(&mut self, id: &str, picture: serde_json::Value) -> bool {
        if self.pictures.get(id) == Some(&picture) {
            return false;
        }
        self.pictures.insert(id.to_owned(), picture);
        true
    }

    /// Forgets the pictures of sources that are gone, so a closed window's picture is not held for the life of the host.
    pub fn keep_pictures_of(&mut self, live: &std::collections::HashSet<String>) {
        self.pictures.retain(|id, _| live.contains(id));
    }

    fn attach_pictures(&self, catalog: &mut CaptureCatalog) {
        for descriptor in catalog.displays.iter_mut().chain(catalog.windows.iter_mut()) {
            descriptor.thumbnail = self.pictures.get(&descriptor.id).cloned();
        }
    }

    /// The catalogue built from the most recent displays, or None before the first update.
    pub fn current(&self) -> Option<&CaptureCatalog> {
        self.current.as_ref()
    }

    /// Returns the new catalogue when the set of displays changed since the last call, and None otherwise.
    pub fn update(&mut self, displays: &[DisplayInfo]) -> Option<CaptureCatalog> {
        self.update_with_windows(displays, &[])
    }

    /// As `update`, with the windows that can be captured listed beside the displays.
    pub fn update_with_windows(&mut self, displays: &[DisplayInfo], windows: &[WindowInfo]) -> Option<CaptureCatalog> {
        let mut catalog = build_catalog(displays, windows);
        self.attach_pictures(&mut catalog);
        if self.current.as_ref() == Some(&catalog) {
            return None;
        }
        self.current = Some(catalog.clone());
        Some(catalog)
    }
}

/// Primary first, then by id, so the ordinals in the titles do not move when the displays are listed in another order.
fn build_catalog(displays: &[DisplayInfo], windows: &[WindowInfo]) -> CaptureCatalog {
    let mut ordered: Vec<&DisplayInfo> = displays.iter().collect();
    ordered.sort_by_key(|display| (!display.is_primary, display.id));
    let descriptors: Vec<CaptureSourceDescriptor> = ordered
        .iter()
        .enumerate()
        .map(|(index, display)| {
            let title = display_title(index + 1, display.is_primary);
            CaptureSourceDescriptor::display(display.id, &title, display.pixel_width, display.pixel_height)
        })
        .collect();
    let (displays, _) = longest_prefix(descriptors, CONTROL_LIST_BUDGET);
    let used = serde_json::to_vec(&displays).map_or(0, |encoded| encoded.len());
    let (windows, _) = longest_prefix(window_descriptors(windows), CONTROL_LIST_BUDGET.saturating_sub(used));
    CaptureCatalog { displays, windows, ..CaptureCatalog::default() }
}

/// By program and then title, ignoring case, so a window's place does not move when the list is read in another order.
fn window_descriptors(windows: &[WindowInfo]) -> Vec<CaptureSourceDescriptor> {
    let mut ordered: Vec<&WindowInfo> = windows.iter().collect();
    ordered.sort_by_key(|window| (window.application.to_lowercase(), window.title.to_lowercase(), window.id));
    ordered
        .into_iter()
        .map(|window| CaptureSourceDescriptor::window(window.id, &window.title, &window.application, window.pixel_width, window.pixel_height))
        .collect()
}

/// What each session has already been sent. A session that has not received the catalogue gets it, whatever the others
/// were sent, so one client never suppresses the picker for another.
#[derive(Debug)]
pub struct SessionCatalogue<K> {
    delivered: HashMap<K, CaptureCatalog>,
}

impl<K: Eq + Hash> Default for SessionCatalogue<K> {
    fn default() -> Self {
        Self { delivered: HashMap::new() }
    }
}

impl<K: Eq + Hash + Clone> SessionCatalogue<K> {
    pub fn new() -> Self {
        Self::default()
    }

    /// The catalogue to send this session, or None when it already holds exactly this one. Recording the send happens here,
    /// so a caller that gets Some must send it.
    pub fn due(&mut self, session: &K, catalog: &CaptureCatalog) -> Option<CaptureCatalog> {
        if self.delivered.get(session) == Some(catalog) {
            return None;
        }
        self.delivered.insert(session.clone(), catalog.clone());
        Some(catalog.clone())
    }

    /// Drops what was recorded for a session that has ended, so its key is not held forever.
    pub fn forget(&mut self, session: &K) {
        self.delivered.remove(session);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display(id: u32, is_primary: bool, width: u32) -> DisplayInfo {
        DisplayInfo {
            id,
            name: format!("Display {id}"),
            pixel_width: width,
            pixel_height: 1080,
            origin_x: 0,
            origin_y: 0,
            scale: 2.0,
            is_primary,
        }
    }

    fn titles(catalog: &CaptureCatalog) -> Vec<&str> {
        catalog.displays.iter().map(|descriptor| descriptor.title.as_str()).collect()
    }

    #[test]
    fn the_catalogue_frame_stays_under_the_64_kib_rule_however_many_displays_there_are() {
        let displays: Vec<DisplayInfo> = (0..1_000).map(|id| display(id, id == 0, 1920)).collect();
        let catalog = build_catalog(&displays, &[]);
        assert!(catalog.displays.len() < 1_000);
        assert!(serde_json::to_vec(&catalog).expect("a catalogue serialises").len() < 64 * 1024);
    }

    fn window(id: u32, application: &str, title: &str) -> WindowInfo {
        WindowInfo {
            id,
            title: title.to_owned(),
            application: application.to_owned(),
            pixel_width: 800,
            pixel_height: 600,
            origin_x: 0,
            origin_y: 0,
            scale: 1.0,
        }
    }

    #[test]
    fn windows_are_listed_by_program_and_then_title() {
        let mut service = CatalogueService::new();
        let windows = [window(3, "Notepad", "b.txt"), window(9, "Edge", "News"), window(4, "notepad", "A.txt")];
        let catalog = service.update_with_windows(&[display(1, true, 1920)], &windows).unwrap();
        let listed: Vec<&str> = catalog.windows.iter().map(|descriptor| descriptor.title.as_str()).collect();
        assert_eq!(listed, ["News", "A.txt", "b.txt"]);
        assert_eq!(catalog.windows[0].id, "window:9");
        assert_eq!(catalog.windows[0].subtitle.as_deref(), Some("Edge"));
        assert_eq!(catalog.windows[0].pixel_size, [800.0, 600.0]);
    }

    #[test]
    fn a_window_that_appears_or_is_renamed_is_a_change() {
        let mut service = CatalogueService::new();
        let displays = [display(1, true, 1920)];
        service.update_with_windows(&displays, &[window(1, "Edge", "News")]);
        assert_eq!(service.update_with_windows(&displays, &[window(1, "Edge", "News")]), None);
        assert!(service.update_with_windows(&displays, &[window(1, "Edge", "Weather")]).is_some());
        assert!(service.update_with_windows(&displays, &[window(1, "Edge", "Weather"), window(2, "Notepad", "x")]).is_some());
    }

    #[test]
    fn the_catalogue_with_windows_stays_under_the_64_kib_rule() {
        let displays = [display(1, true, 1920)];
        let windows: Vec<WindowInfo> = (0..2_000).map(|id| window(id, "Program", &format!("A window with a long title number {id}"))).collect();
        let catalog = build_catalog(&displays, &windows);
        assert!(!catalog.windows.is_empty() && catalog.windows.len() < 2_000);
        assert!(serde_json::to_vec(&catalog).expect("a catalogue serialises").len() < 64 * 1024);
    }

    #[test]
    fn without_windows_the_window_list_is_empty() {
        let mut service = CatalogueService::new();
        let catalog = service.update(&[display(1, true, 1920)]).unwrap();
        assert!(catalog.windows.is_empty());
    }

    #[test]
    fn the_primary_display_is_titled_first_and_marked() {
        assert_eq!(display_title(1, true), "Display 1 (primary)");
        assert_eq!(display_title(2, false), "Display 2");
    }

    #[test]
    fn the_primary_display_is_listed_first_whatever_the_input_order() {
        let mut service = CatalogueService::new();
        let catalog = service.update(&[display(7, false, 1920), display(3, true, 2560)]).unwrap();
        assert_eq!(titles(&catalog), ["Display 1 (primary)", "Display 2"]);
        assert_eq!(catalog.displays[0].source, peering_wire::source::CaptureSource::Display { id: 3 });
    }

    #[test]
    fn descriptors_carry_the_pixel_size_not_the_points() {
        let mut service = CatalogueService::new();
        let catalog = service.update(&[display(1, true, 3024)]).unwrap();
        assert_eq!(catalog.displays[0].pixel_size, [3024.0, 1080.0]);
        assert_eq!(catalog.displays[0].id, "display:1");
    }

    #[test]
    fn the_first_update_always_yields_a_catalogue() {
        let mut service = CatalogueService::new();
        assert!(service.current().is_none());
        assert!(service.update(&[]).is_some());
        assert!(service.current().is_some());
    }

    #[test]
    fn an_unchanged_set_of_displays_yields_nothing() {
        let mut service = CatalogueService::new();
        service.update(&[display(1, true, 1920)]);
        assert_eq!(service.update(&[display(1, true, 1920)]), None);
    }

    #[test]
    fn a_reordered_but_identical_set_is_not_a_change() {
        let mut service = CatalogueService::new();
        service.update(&[display(1, true, 1920), display(2, false, 1280)]);
        assert_eq!(service.update(&[display(2, false, 1280), display(1, true, 1920)]), None);
    }

    #[test]
    fn a_display_added_or_resized_is_a_change() {
        let mut service = CatalogueService::new();
        service.update(&[display(1, true, 1920)]);
        assert!(service.update(&[display(1, true, 1920), display(2, false, 1280)]).is_some());
        assert!(service.update(&[display(1, true, 2560), display(2, false, 1280)]).is_some());
    }

    #[test]
    fn a_session_that_has_not_received_the_catalogue_gets_it() {
        let mut service = CatalogueService::new();
        let catalog = service.update(&[display(1, true, 1920)]).unwrap();
        let mut sessions = SessionCatalogue::new();
        assert_eq!(sessions.due(&"first", &catalog), Some(catalog.clone()));
    }

    #[test]
    fn a_session_is_not_sent_the_same_catalogue_twice() {
        let mut service = CatalogueService::new();
        let catalog = service.update(&[display(1, true, 1920)]).unwrap();
        let mut sessions = SessionCatalogue::new();
        sessions.due(&"first", &catalog);
        assert_eq!(sessions.due(&"first", &catalog), None);
    }

    #[test]
    fn a_later_session_still_gets_the_catalogue_after_an_earlier_one_did() {
        let mut service = CatalogueService::new();
        let catalog = service.update(&[display(1, true, 1920)]).unwrap();
        let mut sessions = SessionCatalogue::new();
        sessions.due(&"first", &catalog);
        assert_eq!(sessions.due(&"second", &catalog), Some(catalog.clone()));
    }

    #[test]
    fn a_changed_catalogue_is_sent_to_a_session_that_held_the_old_one() {
        let mut service = CatalogueService::new();
        let before = service.update(&[display(1, true, 1920)]).unwrap();
        let after = service.update(&[display(1, true, 2560)]).unwrap();
        let mut sessions = SessionCatalogue::new();
        sessions.due(&"first", &before);
        assert_eq!(sessions.due(&"first", &after), Some(after.clone()));
    }

    #[test]
    fn a_forgotten_session_is_sent_the_catalogue_again() {
        let mut service = CatalogueService::new();
        let catalog = service.update(&[display(1, true, 1920)]).unwrap();
        let mut sessions = SessionCatalogue::new();
        sessions.due(&"first", &catalog);
        sessions.forget(&"first");
        assert_eq!(sessions.due(&"first", &catalog), Some(catalog.clone()));
    }

    #[test]
    fn a_new_picture_changes_the_catalogue_and_the_same_picture_does_not() {
        let mut service = CatalogueService::new();
        let displays = [display(1, true, 1920)];
        let windows = [window(7, "Notepad", "notes.txt")];
        assert!(service.update_with_windows(&displays, &windows).is_some());
        assert!(service.update_with_windows(&displays, &windows).is_none());

        let picture = serde_json::json!({ "width": 240, "height": 150, "jpegData": "AQI=" });
        assert!(service.set_picture("window:7", picture.clone()));
        assert!(!service.set_picture("window:7", picture.clone()));
        let changed = service.update_with_windows(&displays, &windows).expect("the picture changes the catalogue");
        assert_eq!(changed.windows[0].thumbnail, Some(picture));
        assert_eq!(changed.displays[0].thumbnail, None);
    }

    #[test]
    fn the_picture_of_a_window_that_is_gone_is_dropped() {
        let mut service = CatalogueService::new();
        let displays = [display(1, true, 1920)];
        let picture = serde_json::json!({ "width": 1, "height": 1, "jpegData": "AQI=" });
        service.set_picture("window:7", picture.clone());
        service.keep_pictures_of(&std::collections::HashSet::new());
        assert!(service.set_picture("window:7", picture));
        let _ = displays;
    }
}
