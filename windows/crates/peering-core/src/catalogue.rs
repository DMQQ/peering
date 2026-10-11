//! The capture catalogue the host pushes to each session, built from the displays the capture port reports.

use std::collections::HashMap;
use std::hash::Hash;

use peering_wire::source::{CaptureCatalog, CaptureSourceDescriptor};

use crate::ports::capture::DisplayInfo;

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
}

impl CatalogueService {
    pub fn new() -> Self {
        Self::default()
    }

    /// The catalogue built from the most recent displays, or None before the first update.
    pub fn current(&self) -> Option<&CaptureCatalog> {
        self.current.as_ref()
    }

    /// Returns the new catalogue when the set of displays changed since the last call, and None otherwise.
    pub fn update(&mut self, displays: &[DisplayInfo]) -> Option<CaptureCatalog> {
        let catalog = build_catalog(displays);
        if self.current.as_ref() == Some(&catalog) {
            return None;
        }
        self.current = Some(catalog.clone());
        Some(catalog)
    }
}

/// Primary first, then by id, so the ordinals in the titles do not move when the displays are listed in another order.
fn build_catalog(displays: &[DisplayInfo]) -> CaptureCatalog {
    let mut ordered: Vec<&DisplayInfo> = displays.iter().collect();
    ordered.sort_by_key(|display| (!display.is_primary, display.id));
    let descriptors = ordered
        .iter()
        .enumerate()
        .map(|(index, display)| {
            let title = display_title(index + 1, display.is_primary);
            CaptureSourceDescriptor::display(display.id, &title, display.pixel_width, display.pixel_height)
        })
        .collect();
    CaptureCatalog { displays: descriptors, ..CaptureCatalog::default() }
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
}
