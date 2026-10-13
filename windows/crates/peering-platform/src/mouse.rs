//! Mouse half of the input sink: pointer moves over the virtual desktop, buttons and the wheel. The builders here are pure
//! and tested on any OS; `SendInput` and the screen metrics live in `mouse/sys.rs`.
//! Wire scroll deltas are in wheel lines. Positive `dy` (the phone's downward drag) becomes a negative wheel delta, and
//! `dx` is negated the same way, both as the Mac host does (`InputInjector.swift`, scroll case).

use peering_core::ports::input::TransformSnapshot;
use peering_wire::command::{MouseButton, RemoteCommand};
use peering_wire::source::NormalizedPoint;
use peering_wire::transform::{to_absolute_mouse, InputTransform};
use std::ops::BitOr;

#[cfg(windows)]
mod sys;
#[cfg(windows)]
use peering_core::ports::input::InputSink;
#[cfg(test)]
mod tests;

/// One wheel notch as Windows counts it.
pub const WHEEL_DELTA: i32 = 120;

/// The raw `MOUSEEVENTF_*` bits, kept as plain numbers so the builders run without the Windows crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MouseFlags(pub u32);

impl MouseFlags {
    pub const MOVE: Self = Self(0x0001);
    pub const LEFT_DOWN: Self = Self(0x0002);
    pub const LEFT_UP: Self = Self(0x0004);
    pub const RIGHT_DOWN: Self = Self(0x0008);
    pub const RIGHT_UP: Self = Self(0x0010);
    pub const MIDDLE_DOWN: Self = Self(0x0020);
    pub const MIDDLE_UP: Self = Self(0x0040);
    pub const WHEEL: Self = Self(0x0800);
    pub const HWHEEL: Self = Self(0x1000);
    pub const VIRTUAL_DESKTOP: Self = Self(0x4000);
    pub const ABSOLUTE: Self = Self(0x8000);
}

impl BitOr for MouseFlags {
    type Output = Self;

    fn bitor(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

/// One `MOUSEINPUT` before it is handed to `SendInput`. `dx` and `dy` only matter for moves; `data` is the wheel delta.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MouseEventSpec {
    pub flags: MouseFlags,
    pub dx: i32,
    pub dy: i32,
    pub data: i32,
}

impl MouseEventSpec {
    fn flagged(flags: MouseFlags) -> Self {
        Self { flags, dx: 0, dy: 0, data: 0 }
    }
}

/// The whole virtual screen, which absolute coordinates span (its left and top can be negative).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VirtualDesktop {
    pub left: i32,
    pub top: i32,
    pub width: i32,
    pub height: i32,
}

/// Maps the normalised point through the captured source to desktop pixels, then to the 0..65535 absolute range.
pub fn move_event(point: NormalizedPoint, transform: &TransformSnapshot, desktop: VirtualDesktop) -> MouseEventSpec {
    let source = InputTransform {
        origin_x: f64::from(transform.origin_x),
        origin_y: f64::from(transform.origin_y),
        pixel_width: f64::from(transform.pixel_width),
        pixel_height: f64::from(transform.pixel_height),
        scale: transform.scale,
    };
    let (x, y) = source.global_point(point.x, point.y);
    let (dx, dy) = to_absolute_mouse(x, y, desktop.left, desktop.top, desktop.width, desktop.height);
    MouseEventSpec {
        flags: MouseFlags::MOVE | MouseFlags::ABSOLUTE | MouseFlags::VIRTUAL_DESKTOP,
        dx,
        dy,
        data: 0,
    }
}

pub fn button_event(button: MouseButton, down: bool) -> MouseEventSpec {
    let flags = match (button, down) {
        (MouseButton::Left, true) => MouseFlags::LEFT_DOWN,
        (MouseButton::Left, false) => MouseFlags::LEFT_UP,
        (MouseButton::Right, true) => MouseFlags::RIGHT_DOWN,
        (MouseButton::Right, false) => MouseFlags::RIGHT_UP,
        (MouseButton::Middle, true) => MouseFlags::MIDDLE_DOWN,
        (MouseButton::Middle, false) => MouseFlags::MIDDLE_UP,
    };
    MouseEventSpec::flagged(flags)
}

/// Fractional wheel notches not yet sent. A slow scroll of a third of a notch per event still moves after three events.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct WheelAccumulator {
    vertical: f64,
    horizontal: f64,
}

/// Non-finite input is dropped rather than stored, because one NaN would otherwise poison the remainder for good.
pub fn wheel_events(dx: f64, dy: f64, accumulator: &mut WheelAccumulator) -> Vec<MouseEventSpec> {
    let mut events = Vec::new();
    if !dx.is_finite() || !dy.is_finite() {
        return events;
    }
    let vertical = take_whole_notches(&mut accumulator.vertical, -dy);
    if vertical != 0 {
        events.push(MouseEventSpec { flags: MouseFlags::WHEEL, dx: 0, dy: 0, data: vertical.saturating_mul(WHEEL_DELTA) });
    }
    let horizontal = take_whole_notches(&mut accumulator.horizontal, -dx);
    if horizontal != 0 {
        events.push(MouseEventSpec { flags: MouseFlags::HWHEEL, dx: 0, dy: 0, data: horizontal.saturating_mul(WHEEL_DELTA) });
    }
    events
}

/// Truncates toward zero, so the remainder keeps the sign of the pending motion and never exceeds one notch.
fn take_whole_notches(pending: &mut f64, notches: f64) -> i32 {
    *pending += notches;
    let whole = pending.trunc();
    *pending -= whole;
    whole as i32
}

/// Builds the mouse events for each command and remembers which buttons are down so a disconnect can release them.
#[derive(Debug, Default)]
pub struct MouseInjector {
    held: Vec<MouseButton>,
    wheel: WheelAccumulator,
    joystick: Option<JoystickPointer>,
}

/// Where the joystick has put the pointer, kept as fractions so a nudge under one pixel is not lost to rounding.
#[derive(Debug, Clone, Copy, PartialEq)]
struct JoystickPointer {
    normalized: (f64, f64),
    global: (f64, f64),
}

/// A pointer this far from where the joystick left it was moved by a hand, and the joystick continues from there.
const HAND_MOVED_PIXELS: f64 = 3.0;
/// The widest picture the phone treats as already measured in points; it halves anything wider (`PointerTravel` in the iPhone app).
const WIDEST_POINT_WIDTH: f64 = 2560.0;

impl MouseInjector {
    pub fn plan(&mut self, command: &RemoteCommand, transform: &TransformSnapshot, desktop: VirtualDesktop) -> Vec<MouseEventSpec> {
        match command {
            RemoteCommand::MouseMove { to } => vec![move_event(*to, transform, desktop)],
            RemoteCommand::MouseDown { button } => {
                self.hold(*button);
                vec![button_event(*button, true)]
            }
            RemoteCommand::MouseUp { button } => {
                self.release(*button);
                vec![button_event(*button, false)]
            }
            RemoteCommand::Scroll { dx, dy } => wheel_events(*dx, *dy, &mut self.wheel),
            _ => Vec::new(),
        }
    }

    /// A joystick nudge arrives in the units of the picture the phone is showing, so the pointer moves by the same
    /// fraction of the picture that the phone's drawn cursor does. `real_cursor` is the pointer's actual position.
    pub fn plan_joystick(
        &mut self,
        dx: f64,
        dy: f64,
        transform: &TransformSnapshot,
        desktop: VirtualDesktop,
        real_cursor: (f64, f64),
    ) -> Vec<MouseEventSpec> {
        if !dx.is_finite() || !dy.is_finite() || transform.pixel_width == 0 || transform.pixel_height == 0 {
            return Vec::new();
        }
        let source = InputTransform {
            origin_x: f64::from(transform.origin_x),
            origin_y: f64::from(transform.origin_y),
            pixel_width: f64::from(transform.pixel_width),
            pixel_height: f64::from(transform.pixel_height),
            scale: transform.scale,
        };
        let moved_by_hand = self.joystick.is_none_or(|last| {
            (real_cursor.0 - last.global.0).hypot(real_cursor.1 - last.global.1) > HAND_MOVED_PIXELS
        });
        let (x, y) = match self.joystick {
            Some(last) if !moved_by_hand => last.normalized,
            _ => source.normalized_point(real_cursor.0, real_cursor.1),
        };
        let phone_width = Self::phone_measure(source.pixel_width);
        let phone_height = Self::phone_measure(source.pixel_height);
        let normalized = ((x + dx / phone_width).clamp(0.0, 1.0), (y + dy / phone_height).clamp(0.0, 1.0));
        let global = source.global_point(normalized.0, normalized.1);
        self.joystick = Some(JoystickPointer { normalized, global });
        vec![move_event(NormalizedPoint { x: normalized.0, y: normalized.1 }, transform, desktop)]
    }

    fn phone_measure(pixels: f64) -> f64 {
        if pixels > WIDEST_POINT_WIDTH { pixels / 2.0 } else { pixels }
    }

    /// Up events for every button still down, and the wheel remainder cleared.
    pub fn release_events(&mut self) -> Vec<MouseEventSpec> {
        self.wheel = WheelAccumulator::default();
        self.held.drain(..).rev().map(|button| button_event(button, false)).collect()
    }

    fn hold(&mut self, button: MouseButton) {
        if !self.held.contains(&button) {
            self.held.push(button);
        }
    }

    fn release(&mut self, button: MouseButton) {
        self.held.retain(|held| *held != button);
    }
}

#[cfg(windows)]
impl InputSink for MouseInjector {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot) {
        let desktop = sys::virtual_desktop();
        let events = match command {
            RemoteCommand::JoystickMove { dx, dy } => {
                self.plan_joystick(*dx, *dy, transform, desktop, sys::cursor_position())
            }
            _ => self.plan(command, transform, desktop),
        };
        sys::send(&events);
    }

    fn release_all(&mut self) {
        let events = self.release_events();
        sys::send(&events);
    }
}
