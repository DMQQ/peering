//! The pictures for the phone's source grid. Shrinking a screenshot and fitting it into the catalogue's size budget are pure
//! and tested on any OS; `thumbnail/sys.rs` takes the screenshots.

use jpeg_encoder::{ColorType, Encoder};
use peering_core::ports::thumbnails::SourceImage;

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::WindowsThumbnails;

/// Pixels across, the width the Mac host uses, so the grid reads the same from either.
const WIDTH: u32 = 240;
/// The most a picture may weigh: the phone refuses anything over 32 KiB, and every catalogue carries all of them.
const MAXIMUM_BYTES: usize = 32 * 1024;
const FIRST_QUALITY: u8 = 45;
const LOWEST_QUALITY: u8 = 20;
const QUALITY_STEP: u8 = 8;

/// A screenshot as the GDI hands it over: top row first, four bytes a pixel, blue first.
pub struct Screenshot<'a> {
    pub width: u32,
    pub height: u32,
    pub bgra: &'a [u8],
}

/// The screenshot shrunk to the grid's width and compressed, or `None` when it is empty, malformed, or too heavy even at the
/// lowest quality.
pub fn thumbnail_from(screenshot: &Screenshot<'_>) -> Option<SourceImage> {
    let (width, height) = fitted_size(screenshot.width, screenshot.height)?;
    let rgb = shrink(screenshot, width, height)?;
    let jpeg = compress_within(&rgb, width, height)?;
    Some(SourceImage { width, height, jpeg })
}

/// The size at `WIDTH` across with the screenshot's shape, never larger than the screenshot and never zero.
fn fitted_size(width: u32, height: u32) -> Option<(u32, u32)> {
    if width == 0 || height == 0 {
        return None;
    }
    let across = width.min(WIDTH);
    let down = (u64::from(height) * u64::from(across) / u64::from(width)).max(1);
    Some((across, u32::try_from(down).ok()?))
}

/// Averages the source pixels each output pixel covers, which keeps small text legible where picking one pixel would not.
fn shrink(screenshot: &Screenshot<'_>, width: u32, height: u32) -> Option<Vec<u8>> {
    let (source_width, source_height) = (screenshot.width as usize, screenshot.height as usize);
    if screenshot.bgra.len() < source_width.checked_mul(source_height)?.checked_mul(4)? {
        return None;
    }
    let mut rgb = Vec::with_capacity(width as usize * height as usize * 3);
    for row in 0..height as usize {
        let (top, bottom) = span(row, height as usize, source_height);
        for column in 0..width as usize {
            let (left, right) = span(column, width as usize, source_width);
            let mut sums = [0u64; 3];
            for y in top..bottom {
                for x in left..right {
                    let at = (y * source_width + x) * 4;
                    sums[0] += u64::from(screenshot.bgra[at + 2]);
                    sums[1] += u64::from(screenshot.bgra[at + 1]);
                    sums[2] += u64::from(screenshot.bgra[at]);
                }
            }
            let count = ((bottom - top) * (right - left)) as u64;
            rgb.extend(sums.iter().map(|sum| (sum / count) as u8));
        }
    }
    Some(rgb)
}

/// The source rows or columns an output index covers: at least one, and the last output ends at the edge.
fn span(index: usize, outputs: usize, inputs: usize) -> (usize, usize) {
    let start = index * inputs / outputs;
    let end = ((index + 1) * inputs / outputs).max(start + 1).min(inputs);
    (start.min(inputs - 1), end)
}

/// Lowers the quality until the picture fits the budget, as the Mac host does.
fn compress_within(rgb: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    let mut quality = FIRST_QUALITY;
    loop {
        let mut jpeg = Vec::new();
        let encoder = Encoder::new(&mut jpeg, quality);
        encoder.encode(rgb, u16::try_from(width).ok()?, u16::try_from(height).ok()?, ColorType::Rgb).ok()?;
        if jpeg.len() <= MAXIMUM_BYTES {
            return Some(jpeg);
        }
        if quality <= LOWEST_QUALITY {
            return None;
        }
        quality = quality.saturating_sub(QUALITY_STEP).max(LOWEST_QUALITY);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(width: u32, height: u32, blue: u8, green: u8, red: u8) -> Vec<u8> {
        [blue, green, red, 255].repeat((width * height) as usize)
    }

    #[test]
    fn a_wide_screenshot_is_shrunk_to_the_grid_width_keeping_its_shape() {
        let pixels = solid(1920, 1080, 10, 20, 30);
        let image = thumbnail_from(&Screenshot { width: 1920, height: 1080, bgra: &pixels }).expect("a picture");
        assert_eq!((image.width, image.height), (240, 135));
        assert_eq!(&image.jpeg[..2], &[0xFF, 0xD8]);
    }

    #[test]
    fn a_screenshot_narrower_than_the_grid_is_not_enlarged() {
        let pixels = solid(100, 50, 0, 0, 0);
        let image = thumbnail_from(&Screenshot { width: 100, height: 50, bgra: &pixels }).expect("a picture");
        assert_eq!((image.width, image.height), (100, 50));
    }

    #[test]
    fn a_very_flat_screenshot_keeps_at_least_one_row() {
        let pixels = solid(2000, 1, 0, 0, 0);
        let image = thumbnail_from(&Screenshot { width: 2000, height: 1, bgra: &pixels }).expect("a picture");
        assert_eq!(image.height, 1);
    }

    #[test]
    fn an_empty_or_short_screenshot_gives_no_picture() {
        assert!(thumbnail_from(&Screenshot { width: 0, height: 10, bgra: &[] }).is_none());
        assert!(thumbnail_from(&Screenshot { width: 10, height: 10, bgra: &[0; 12] }).is_none());
    }

    #[test]
    fn shrinking_averages_the_pixels_and_swaps_blue_and_red() {
        let mut pixels = solid(2, 1, 0, 0, 0);
        pixels[..4].copy_from_slice(&[0, 0, 200, 255]);
        pixels[4..].copy_from_slice(&[0, 0, 100, 255]);
        let rgb = shrink(&Screenshot { width: 2, height: 1, bgra: &pixels }, 1, 1).expect("a pixel");
        assert_eq!(rgb, vec![150, 0, 0]);
    }

    #[test]
    fn noise_that_cannot_fit_the_budget_is_dropped_rather_than_sent_oversize() {
        let mut state = 12345u32;
        let pixels: Vec<u8> = (0..240 * 240 * 4)
            .map(|_| {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (state >> 24) as u8
            })
            .collect();
        let picture = thumbnail_from(&Screenshot { width: 240, height: 240, bgra: &pixels });
        assert!(picture.is_none_or(|image| image.jpeg.len() <= MAXIMUM_BYTES));
    }

    #[test]
    fn the_spans_of_the_outputs_tile_the_input() {
        let spans: Vec<(usize, usize)> = (0..3).map(|index| span(index, 3, 10)).collect();
        assert_eq!(spans, vec![(0, 3), (3, 6), (6, 10)]);
        assert_eq!(span(0, 5, 2), (0, 1));
    }
}
