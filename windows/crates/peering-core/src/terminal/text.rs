//! Character classes the detectors share, matching what Foundation treats as a newline and as horizontal space.

pub(super) fn is_newline(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

pub(super) fn is_horizontal_space(character: char) -> bool {
    character == '\t' || (character.is_whitespace() && !is_newline(character))
}

pub(super) fn trim_horizontal(text: &str) -> &str {
    text.trim_matches(is_horizontal_space)
}

/// The non-empty lines of `text`, where a CRLF pair is one separator.
pub(super) fn lines(text: &str) -> impl Iterator<Item = &str> {
    text.split(is_newline).filter(|line| !line.is_empty())
}
