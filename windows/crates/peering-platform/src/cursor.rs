//! The mouse pointer in the picture. Desktop Duplication delivers the desktop without the pointer, with the pointer's shape and
//! position beside it, so the host draws the pointer into each frame it sends, as the Mac does for the phone's sake. The
//! shape formats, the clipping and the blending are pure and tested on any OS; `dda/sys/cursor.rs` moves the pixels.

use std::sync::atomic::{AtomicBool, Ordering};

static IN_PICTURE: AtomicBool = AtomicBool::new(true);

/// Whether the host draws the pointer into the picture. On unless the settings turn it off.
pub fn cursor_in_picture() -> bool {
    IN_PICTURE.load(Ordering::Relaxed)
}

pub fn set_cursor_in_picture(on: bool) {
    IN_PICTURE.store(on, Ordering::Relaxed);
}

/// `DXGI_OUTDUPL_POINTER_SHAPE_TYPE`.
const SHAPE_MONOCHROME: u32 = 1;
const SHAPE_COLOR: u32 = 2;
const SHAPE_MASKED_COLOR: u32 = 4;

/// The largest pointer the host draws, in pixels on a side. Accessibility pointers can be larger; they are not drawn.
pub const MAX_SIDE: u32 = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShapeKind {
    /// 1 bit per pixel: an AND mask, then an XOR mask below it.
    Monochrome,
    /// 32 bit BGRA with straight alpha.
    Color,
    /// 32 bit BGRA whose alpha says how the pixel combines with the screen: 0 replaces it, anything else is XORed in.
    MaskedColor,
}

impl ShapeKind {
    pub fn from_dxgi(kind: u32) -> Option<Self> {
        match kind {
            SHAPE_MONOCHROME => Some(Self::Monochrome),
            SHAPE_COLOR => Some(Self::Color),
            SHAPE_MASKED_COLOR => Some(Self::MaskedColor),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorShape {
    kind: ShapeKind,
    width: u32,
    /// Rows of the picture of the pointer; a monochrome buffer holds twice as many.
    height: u32,
    pitch: usize,
    data: Vec<u8>,
}

impl CursorShape {
    /// `buffer_height` is the height DXGI reports, which for a monochrome shape counts both masks. `None` for a shape
    /// that is empty, too large, or whose buffer is too short for what it declares.
    pub fn new(kind: ShapeKind, width: u32, buffer_height: u32, pitch: u32, data: Vec<u8>) -> Option<Self> {
        let height = if kind == ShapeKind::Monochrome { buffer_height / 2 } else { buffer_height };
        let pitch = pitch as usize;
        let row_bytes = match kind {
            ShapeKind::Monochrome => (width as usize).div_ceil(8),
            ShapeKind::Color | ShapeKind::MaskedColor => width as usize * 4,
        };
        let rows = if kind == ShapeKind::Monochrome { height as usize * 2 } else { height as usize };
        let fits = width > 0 && height > 0 && width <= MAX_SIDE && height <= MAX_SIDE && pitch >= row_bytes;
        let complete = rows.checked_mul(pitch).is_some_and(|needed| data.len() >= needed);
        (fits && complete).then_some(Self { kind, width, height, pitch, data })
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }
}

/// Where a pointer lands on a frame: the part of the frame it covers, and which part of the pointer that is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub shape_x: u32,
    pub shape_y: u32,
}

/// The part of a `shape_width` by `shape_height` pointer whose top left corner is at (`left`, `top`) that lies on a frame of
/// `frame` pixels. `None` when none of it does.
pub fn place(frame: (u32, u32), shape: (u32, u32), left: i32, top: i32) -> Option<Placement> {
    let clip = |origin: i32, length: u32, limit: u32| -> Option<(u32, u32, u32)> {
        let start = i64::from(origin);
        let end = start + i64::from(length);
        let visible_start = start.max(0);
        let visible_end = end.min(i64::from(limit));
        (visible_end > visible_start).then(|| (visible_start as u32, (visible_end - visible_start) as u32, (visible_start - start) as u32))
    };
    let (x, width, shape_x) = clip(left, shape.0, frame.0)?;
    let (y, height, shape_y) = clip(top, shape.1, frame.1)?;
    Some(Placement { x, y, width, height, shape_x, shape_y })
}

impl CursorShape {
    /// Draws the pointer over `patch`, BGRA rows of `placement.width` pixels `patch_pitch` bytes apart, which hold the part of
    /// the frame the placement covers.
    pub fn draw(&self, patch: &mut [u8], patch_pitch: usize, placement: &Placement) {
        for row in 0..placement.height {
            for column in 0..placement.width {
                let at = row as usize * patch_pitch + column as usize * 4;
                if let Some(pixel) = patch.get_mut(at..at + 4) {
                    self.draw_pixel(pixel, placement.shape_x + column, placement.shape_y + row);
                }
            }
        }
    }

    fn draw_pixel(&self, pixel: &mut [u8], column: u32, row: u32) {
        match self.kind {
            ShapeKind::Color | ShapeKind::MaskedColor => {
                let at = row as usize * self.pitch + column as usize * 4;
                let source = [self.data[at], self.data[at + 1], self.data[at + 2], self.data[at + 3]];
                if self.kind == ShapeKind::Color {
                    for channel in 0..3 {
                        pixel[channel] = blend(source[channel], pixel[channel], source[3]);
                    }
                } else {
                    for channel in 0..3 {
                        pixel[channel] = if source[3] == 0 { source[channel] } else { pixel[channel] ^ source[channel] };
                    }
                }
            }
            ShapeKind::Monochrome => {
                let keep = self.bit(row, column);
                let invert = self.bit(self.height + row, column);
                for value in pixel.iter_mut().take(3) {
                    *value = (if keep { *value } else { 0 }) ^ (if invert { 0xFF } else { 0 });
                }
            }
        }
    }

    fn bit(&self, row: u32, column: u32) -> bool {
        let byte = self.data[row as usize * self.pitch + column as usize / 8];
        byte & (0x80 >> (column % 8)) != 0
    }
}

fn blend(source: u8, below: u8, alpha: u8) -> u8 {
    let alpha = u32::from(alpha);
    ((u32::from(source) * alpha + u32::from(below) * (255 - alpha) + 127) / 255) as u8
}

/// What the pointer was last reported as doing, and whether a report changed anything that is drawn.
#[derive(Debug, Default)]
pub struct PointerState {
    position: (i32, i32),
    visible: bool,
    shape: Option<CursorShape>,
}

impl PointerState {
    /// Takes what a frame reported. `position` is `None` when the frame carries no pointer update, and `shape` is `None`
    /// unless the pointer changed shape. Returns whether the pointer must be drawn again.
    pub fn update(&mut self, position: Option<((i32, i32), bool)>, shape: Option<CursorShape>) -> bool {
        let mut changed = false;
        if let Some((at, visible)) = position {
            changed |= self.position != at || self.visible != visible;
            self.position = at;
            self.visible = visible;
        }
        if let Some(shape) = shape {
            changed |= self.shape.as_ref() != Some(&shape);
            self.shape = Some(shape);
        }
        changed
    }

    /// The pointer to draw and its top left corner, or `None` when it is hidden or has no shape.
    pub fn visible(&self) -> Option<(&CursorShape, (i32, i32))> {
        let shape = self.shape.as_ref().filter(|_| self.visible)?;
        Some((shape, self.position))
    }

    /// Forgets everything, for when the capture starts again on another output.
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod switch_tests {
    use super::*;

    #[test]
    fn the_pointer_is_drawn_unless_switched_off() {
        assert!(cursor_in_picture());
        set_cursor_in_picture(false);
        assert!(!cursor_in_picture());
        set_cursor_in_picture(true);
    }
}
