//! Decides when the phone is told where the PC's pointer is, as `PointerWatcher.swift` and the joystick settle report do on
//! the Mac. The joystick sends the phone only a delta, so without a report its drawn cursor keeps the spot it last estimated.

use peering_wire::source::NormalizedPoint;
use peering_wire::transform::InputTransform;

use crate::ports::input::TransformSnapshot;

/// Under this the pointer is where the sink last put it: rounding a point to a pixel is not a hand.
const INJECTED_TOLERANCE_PIXELS: f64 = 2.0;
/// How long after the last joystick nudge the pointer is reported where it came to rest.
pub const SETTLE_SECONDS: f64 = 0.3;

/// What one look at the pointer found.
pub struct PointerView {
    /// Where the real pointer is, in desktop pixels.
    pub cursor: (f64, f64),
    /// Where the host last put it for a phone.
    pub injected: Option<(f64, f64)>,
    /// The sink's count of joystick nudges, which rises when a new one arrives.
    pub nudges: u64,
    pub transform: TransformSnapshot,
}

#[derive(Debug, Default)]
pub struct PointerTracker {
    last_seen: Option<(f64, f64)>,
    nudges_seen: u64,
    settle_at: Option<f64>,
}

impl PointerTracker {
    /// Forgets what was seen, for when no phone is connected. The next look is a new baseline.
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// The point to report now, if any: where a joystick nudge came to rest, or where a hand left the pointer.
    pub fn look(&mut self, now: f64, view: &PointerView) -> Option<NormalizedPoint> {
        if view.nudges != self.nudges_seen {
            self.nudges_seen = view.nudges;
            self.settle_at = Some(now + SETTLE_SECONDS);
        }
        if self.settle_at.is_some_and(|due| now >= due) {
            self.settle_at = None;
            self.last_seen = Some(view.cursor);
            return Some(normalised(view.injected.unwrap_or(view.cursor), &view.transform));
        }
        let Some(previous) = self.last_seen else {
            self.last_seen = Some(view.cursor);
            return None;
        };
        if distance(view.cursor, previous) <= INJECTED_TOLERANCE_PIXELS {
            return None;
        }
        self.last_seen = Some(view.cursor);
        let driven_by_phone = self.settle_at.is_some()
            || view.injected.is_some_and(|injected| distance(view.cursor, injected) <= INJECTED_TOLERANCE_PIXELS);
        (!driven_by_phone).then(|| normalised(view.cursor, &view.transform))
    }
}

fn distance(a: (f64, f64), b: (f64, f64)) -> f64 {
    (a.0 - b.0).hypot(a.1 - b.1)
}

/// Where a desktop pixel lies in the captured source, 0 to 1 across it; outside that range when the pixel is off the source.
pub(crate) fn unclamped(global: (f64, f64), transform: &TransformSnapshot) -> (f64, f64) {
    let source = InputTransform {
        origin_x: f64::from(transform.origin_x),
        origin_y: f64::from(transform.origin_y),
        pixel_width: f64::from(transform.pixel_width),
        pixel_height: f64::from(transform.pixel_height),
        scale: transform.scale,
    };
    source.normalized_point(global.0, global.1)
}

fn normalised(global: (f64, f64), transform: &TransformSnapshot) -> NormalizedPoint {
    let (x, y) = unclamped(global, transform);
    NormalizedPoint { x: x.clamp(0.0, 1.0), y: y.clamp(0.0, 1.0) }
}

#[cfg(test)]
mod tests;
