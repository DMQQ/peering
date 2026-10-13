//! The Windows clipboard for the host's clipboard port: Unicode text, and pictures as `CF_DIBV5` converted to and from PNG.
//! The text conversions are pure and tested on any OS; the clipboard calls live in `clipboard/sys.rs`.

#[cfg(windows)]
mod sys;
#[cfg(test)]
mod tests;

#[cfg(windows)]
pub use sys::WindowsClipboard;

/// The text as the clipboard stores it: UTF-16 with a terminating zero.
pub fn utf16_with_terminator(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

/// The text up to the first zero. A lone surrogate becomes the replacement character, since the phone cannot show it.
pub fn text_from_utf16(units: &[u16]) -> String {
    let end = units.iter().position(|unit| *unit == 0).unwrap_or(units.len());
    String::from_utf16_lossy(&units[..end])
}
