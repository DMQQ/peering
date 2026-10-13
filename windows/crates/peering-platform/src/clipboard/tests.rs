use super::*;

#[test]
fn text_is_stored_with_a_terminating_zero() {
    assert_eq!(utf16_with_terminator("hi"), [104, 105, 0]);
    assert_eq!(utf16_with_terminator(""), [0]);
}

#[test]
fn text_outside_the_basic_plane_survives_a_round_trip() {
    let text = "naïve 😀 日本";
    assert_eq!(text_from_utf16(&utf16_with_terminator(text)), text);
}

#[test]
fn reading_stops_at_the_first_zero() {
    assert_eq!(text_from_utf16(&[104, 105, 0, 120, 121]), "hi");
}

#[test]
fn reading_without_a_terminator_takes_everything() {
    assert_eq!(text_from_utf16(&[104, 105]), "hi");
}

#[test]
fn a_lone_surrogate_becomes_the_replacement_character() {
    assert_eq!(text_from_utf16(&[0xD800, 0]), "\u{FFFD}");
}
