//! Turns text into the dark and light modules of a QR code, so the window can paint it. Pure: no drawing here.

use qrcode::{Color, QrCode};

/// The modules of one code, row by row from the top left. `dark[y * width + x]` is true for a dark module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Modules {
    pub width: usize,
    pub dark: Vec<bool>,
}

impl Modules {
    pub fn is_dark(&self, x: usize, y: usize) -> bool {
        self.dark[y * self.width + x]
    }
}

/// `None` when the text is too long for a QR code, which the caller shows as a message instead.
pub fn modules_for(content: &str) -> Option<Modules> {
    let code = QrCode::new(content.as_bytes()).ok()?;
    let width = code.width();
    let dark = code.to_colors().into_iter().map(|color| color == Color::Dark).collect();
    Some(Modules { width, dark })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_short_text_fits_the_smallest_code_with_its_finder_patterns_dark() {
        let modules = modules_for("A").expect("short text fits");
        assert_eq!(modules.width, 21);
        for (x, y) in [(0, 0), (6, 0), (0, 6), (6, 6), (3, 3)] {
            assert!(modules.is_dark(x, y), "module ({x}, {y}) is part of a finder pattern");
        }
    }

    #[test]
    fn the_same_text_gives_the_same_modules() {
        assert_eq!(modules_for("peering://host/ABC"), modules_for("peering://host/ABC"));
    }

    #[test]
    fn a_text_longer_than_a_code_holds_is_refused() {
        let too_long = "x".repeat(8000);
        assert_eq!(modules_for(&too_long), None);
    }
}
