use super::*;

const TRANSFORM: TransformSnapshot = TransformSnapshot { origin_x: 0, origin_y: 0, pixel_width: 1000, pixel_height: 500, scale: 1.0 };

fn field(element: u64, text: &str) -> FocusSnapshot {
    FocusSnapshot {
        element,
        editable: true,
        secure: false,
        terminal: false,
        text: Some(text.to_owned()),
        selection: Some((text.encode_utf16().count() as u32, 0)),
        caret: Some((500.0, 250.0)),
    }
}

fn label(element: u64) -> FocusSnapshot {
    FocusSnapshot { editable: false, text: None, selection: None, caret: None, ..field(element, "") }
}

fn feed(watcher: &mut FocusWatcher, snapshot: Option<FocusSnapshot>) -> Vec<FocusMessage> {
    watcher.on_report(&FocusReport::Focus(snapshot), &TRANSFORM)
}

fn editable(message: &FocusMessage) -> Option<bool> {
    match message {
        FocusMessage::Focus(focus) => Some(focus.is_editable),
        FocusMessage::Field(_) => None,
    }
}

#[test]
fn where_focus_already_is_when_watching_starts_does_not_open_the_keyboard() {
    let mut watcher = FocusWatcher::default();
    assert!(feed(&mut watcher, Some(field(1, "hello"))).is_empty());
    let next = feed(&mut watcher, Some(field(1, "hello")));
    assert_eq!(next.len(), 1, "the field the person is already in is mirrored, as on the Mac");
    assert!(matches!(next[0], FocusMessage::Field(_)), "but no textFocus tells the phone to raise its keyboard");
    assert!(feed(&mut watcher, Some(field(1, "hello"))).is_empty(), "and it stays quiet while nothing changes");
}

#[test]
fn moving_into_a_text_field_sends_the_focus_and_then_the_field() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(1)));
    let messages = feed(&mut watcher, Some(field(2, "hi")));
    assert_eq!(messages.len(), 2);
    assert_eq!(editable(&messages[0]), Some(true));
    let FocusMessage::Field(state) = &messages[1] else { panic!("a field state follows") };
    assert_eq!(state.text.as_deref(), Some("hi"));
    assert_eq!((state.selection_location, state.selection_length), (2, 0));
    assert_eq!(state.caret, Some(NormalizedPoint { x: 0.5, y: 0.5 }));
}

#[test]
fn moving_onto_something_that_does_not_take_typing_says_so_and_sends_no_field() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(field(1, "x")));
    let messages = feed(&mut watcher, Some(label(2)));
    assert_eq!(messages.iter().map(editable).collect::<Vec<_>>(), vec![Some(false)]);
}

#[test]
fn typing_in_the_same_field_sends_only_the_field() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(1)));
    feed(&mut watcher, Some(field(2, "h")));
    let messages = feed(&mut watcher, Some(field(2, "he")));
    assert_eq!(messages.len(), 1);
    assert!(matches!(&messages[0], FocusMessage::Field(state) if state.text.as_deref() == Some("he")));
    assert!(feed(&mut watcher, Some(field(2, "he"))).is_empty());
}

#[test]
fn a_moved_selection_is_a_change() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(1)));
    feed(&mut watcher, Some(field(2, "hello")));
    let moved = FocusSnapshot { selection: Some((1, 2)), ..field(2, "hello") };
    let messages = feed(&mut watcher, Some(moved));
    assert!(matches!(&messages[0], FocusMessage::Field(state) if (state.selection_location, state.selection_length) == (1, 2)));
}

#[test]
fn focus_leaving_every_element_is_not_editable_once() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(field(1, "x")));
    let messages = feed(&mut watcher, None);
    assert_eq!(messages.iter().map(editable).collect::<Vec<_>>(), vec![Some(false)]);
    assert!(feed(&mut watcher, None).is_empty());
}

#[test]
fn coming_back_to_the_same_field_after_a_move_sends_it_again() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(9)));
    feed(&mut watcher, Some(field(1, "x")));
    feed(&mut watcher, Some(label(2)));
    let messages = feed(&mut watcher, Some(field(1, "x")));
    assert_eq!(messages.len(), 2, "the focus and the field both");
}

#[test]
fn a_password_field_sends_neither_its_text_nor_its_caret() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(1)));
    let secret = FocusSnapshot { secure: true, ..field(2, "hunter2") };
    let messages = feed(&mut watcher, Some(secret));
    let FocusMessage::Field(state) = &messages[1] else { panic!("a field state follows") };
    assert_eq!(state.text, None);
    assert_eq!(state.caret, None);
    assert_eq!((state.selection_location, state.selection_length), (7, 0), "the selection is still the field's own");
}

#[test]
fn a_terminal_sends_no_text() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(1)));
    let terminal = FocusSnapshot { terminal: true, selection: None, ..field(2, "C:\\> dir") };
    let messages = feed(&mut watcher, Some(terminal));
    let FocusMessage::Field(state) = &messages[1] else { panic!("a field state follows") };
    assert_eq!(state.text, None);
    assert_eq!((state.selection_location, state.selection_length), (0, 0));
}

#[test]
fn a_document_sized_field_sends_no_text() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(1)));
    let long = "a".repeat(LONGEST_READABLE_TEXT + 1);
    let messages = feed(&mut watcher, Some(field(2, &long)));
    let FocusMessage::Field(state) = &messages[1] else { panic!("a field state follows") };
    assert_eq!(state.text, None);
    assert_eq!(state.selection_location as usize, LONGEST_READABLE_TEXT + 1);
}

#[test]
fn text_counted_in_utf16_units_puts_the_caret_after_a_surrogate_pair_at_two() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(1)));
    let mut emoji = field(2, "\u{1F600}");
    emoji.selection = None;
    let messages = feed(&mut watcher, Some(emoji));
    let FocusMessage::Field(state) = &messages[1] else { panic!("a field state follows") };
    assert_eq!(state.selection_location, 2);
}

#[test]
fn a_caret_off_the_captured_screen_is_left_out() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(label(1)));
    let off = FocusSnapshot { caret: Some((1500.0, 100.0)), ..field(2, "x") };
    let messages = feed(&mut watcher, Some(off));
    let FocusMessage::Field(state) = &messages[1] else { panic!("a field state follows") };
    assert_eq!(state.caret, None);
}

#[test]
fn a_tap_reports_what_it_landed_on_even_when_focus_did_not_move() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(field(1, "x")));
    let messages = watcher.on_report(&FocusReport::Tapped { editable: true }, &TRANSFORM);
    assert_eq!(messages, vec![FocusMessage::Focus(TextFocus { is_editable: true })]);
}

#[test]
fn a_tap_before_the_baseline_is_ignored() {
    let mut watcher = FocusWatcher::default();
    assert!(watcher.on_report(&FocusReport::Tapped { editable: true }, &TRANSFORM).is_empty());
}

#[test]
fn reset_makes_the_next_look_a_baseline_again() {
    let mut watcher = FocusWatcher::default();
    feed(&mut watcher, Some(field(1, "x")));
    watcher.reset();
    assert!(feed(&mut watcher, Some(field(2, "y"))).is_empty());
}
