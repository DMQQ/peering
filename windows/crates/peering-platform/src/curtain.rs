//! Privacy mode's cover: one black, topmost, click-through window per monitor, kept out of capture so the phone still
//! sees the desktop. The layout decisions are pure and tested on any OS; the windows live in `curtain/sys.rs`.

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::WindowsCurtain;

use crate::monitors::MonitorReading;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoverRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// What to do to the covers up now so they match the monitors attached now.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct CoverPlan {
    pub close: Vec<String>,
    pub resize: Vec<(String, CoverRect)>,
    pub open: Vec<(String, CoverRect)>,
}

/// One cover per monitor with an area, keyed by its device name.
pub fn wanted_covers(readings: &[MonitorReading]) -> Vec<(String, CoverRect)> {
    readings
        .iter()
        .filter(|reading| reading.size_px.0 > 0 && reading.size_px.1 > 0)
        .map(|reading| {
            let size = |pixels: u32| i32::try_from(pixels).unwrap_or(i32::MAX);
            let rect = CoverRect {
                x: reading.origin_px.0,
                y: reading.origin_px.1,
                width: size(reading.size_px.0),
                height: size(reading.size_px.1),
            };
            (reading.device_name.clone(), rect)
        })
        .collect()
}

/// Works from the monitor list, not remembered state, so a monitor attached while covered does not escape.
pub fn plan(current: &[(String, CoverRect)], wanted: &[(String, CoverRect)]) -> CoverPlan {
    let mut plan = CoverPlan::default();
    for (name, _) in current {
        if !wanted.iter().any(|(wanted_name, _)| wanted_name == name) {
            plan.close.push(name.clone());
        }
    }
    for (name, rect) in wanted {
        match current.iter().find(|(current_name, _)| current_name == name) {
            Some((_, up)) if up == rect => {}
            Some(_) => plan.resize.push((name.clone(), *rect)),
            None => plan.open.push((name.clone(), *rect)),
        }
    }
    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(name: &str, origin: (i32, i32), size: (u32, u32)) -> MonitorReading {
        MonitorReading { device_name: name.to_owned(), adapter_name: None, origin_px: origin, size_px: size, dpi: 96, is_primary: false }
    }

    fn rect(x: i32, y: i32, width: i32, height: i32) -> CoverRect {
        CoverRect { x, y, width, height }
    }

    #[test]
    fn every_monitor_with_an_area_gets_a_cover_where_it_sits() {
        let covers = wanted_covers(&[reading("A", (0, 0), (1920, 1080)), reading("B", (-1280, 0), (1280, 1024)), reading("C", (0, 0), (0, 0))]);
        assert_eq!(covers, [("A".to_owned(), rect(0, 0, 1920, 1080)), ("B".to_owned(), rect(-1280, 0, 1280, 1024))]);
    }

    #[test]
    fn a_change_of_monitors_closes_moves_and_opens_only_what_differs() {
        let current = [("A".to_owned(), rect(0, 0, 10, 10)), ("B".to_owned(), rect(10, 0, 10, 10)), ("C".to_owned(), rect(20, 0, 5, 5))];
        let wanted = [("A".to_owned(), rect(0, 0, 10, 10)), ("B".to_owned(), rect(10, 0, 20, 20)), ("D".to_owned(), rect(30, 0, 5, 5))];
        let planned = plan(&current, &wanted);
        assert_eq!(planned.close, ["C"]);
        assert_eq!(planned.resize, [("B".to_owned(), rect(10, 0, 20, 20))]);
        assert_eq!(planned.open, [("D".to_owned(), rect(30, 0, 5, 5))]);
    }
}
