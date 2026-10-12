use super::*;

const KEY_A: u16 = 0;
const LEFT_SHIFT: u16 = 56;
const LEFT_COMMAND: u16 = 55;
const LEFT_CONTROL: u16 = 59;
const C: u16 = 8;
const RIGHT_ARROW: u16 = 124;
const WINDOWS_KEY: u16 = 256;

fn scan(scancode: u16, extended: bool) -> KeyTarget {
    KeyTarget { scancode, extended }
}

fn key(target: KeyTarget, key_up: bool, chord_modifier: bool) -> KeyEventSpec {
    KeyEventSpec { input: KeyInput::Scancode(target), key_up, chord_modifier }
}

fn control() -> KeyTarget {
    scan(0x1D, false)
}

fn shift() -> KeyTarget {
    scan(0x2A, false)
}

#[test]
fn a_letter_key_down_and_up_are_plain_scancode_events() {
    assert_eq!(key_events(KEY_A, Modifiers::NONE, true), vec![key(scan(0x1E, false), false, false)]);
    assert_eq!(key_events(KEY_A, Modifiers::NONE, false), vec![key(scan(0x1E, false), true, false)]);
}

#[test]
fn an_extended_key_keeps_its_extended_flag() {
    assert_eq!(key_events(RIGHT_ARROW, Modifiers::NONE, true), vec![key(scan(0x4D, true), false, false)]);
}

#[test]
fn the_windows_key_is_the_extended_left_meta_scancode() {
    assert_eq!(key_events(WINDOWS_KEY, Modifiers::NONE, true), vec![key(scan(0x5B, true), false, false)]);
}

#[test]
fn an_unknown_keycode_sends_nothing() {
    assert!(key_events(200, Modifiers::NONE, true).is_empty());
}

#[test]
fn a_modifier_keycode_is_a_plain_key_even_when_flagged() {
    assert_eq!(key_events(LEFT_SHIFT, Modifiers::SHIFT, true), vec![key(shift(), false, false)]);
    assert_eq!(key_events(LEFT_SHIFT, Modifiers::SHIFT, false), vec![key(shift(), true, false)]);
}

#[test]
fn a_chord_presses_modifiers_before_the_key_and_releases_them_after_in_reverse() {
    let modifiers = Modifiers(Modifiers::SHIFT.0 | Modifiers::COMMAND.0);
    let down = key_events(C, modifiers, true);
    assert_eq!(down, vec![key(shift(), false, true), key(control(), false, true), key(scan(0x2E, false), false, false)]);
    let up = key_events(C, modifiers, false);
    assert_eq!(up, vec![key(scan(0x2E, false), true, false), key(control(), true, true), key(shift(), true, true)]);
}

#[test]
fn command_is_sent_as_control_and_appears_once_with_control_flag() {
    let modifiers = Modifiers(Modifiers::COMMAND.0 | Modifiers::CONTROL.0);
    let down = key_events(C, modifiers, true);
    assert_eq!(down.iter().filter(|spec| spec.chord_modifier).count(), 1);
}

#[test]
fn a_unicode_bmp_character_is_one_down_and_one_up() {
    assert_eq!(
        unicode_events("a"),
        vec![
            KeyEventSpec { input: KeyInput::Unicode(0x61), key_up: false, chord_modifier: false },
            KeyEventSpec { input: KeyInput::Unicode(0x61), key_up: true, chord_modifier: false },
        ]
    );
}

#[test]
fn a_surrogate_pair_stays_two_adjacent_units_each_pressed_and_released() {
    let units: Vec<(u16, bool)> = unicode_events("\u{1F600}")
        .iter()
        .map(|spec| match spec.input {
            KeyInput::Unicode(unit) => (unit, spec.key_up),
            KeyInput::Scancode(_) => panic!("text must not produce scancodes"),
        })
        .collect();
    assert_eq!(units, vec![(0xD83D, false), (0xD83D, true), (0xDE00, false), (0xDE00, true)]);
}

#[test]
fn an_empty_text_produces_no_events() {
    assert!(unicode_events("").is_empty());
}

#[test]
fn a_held_key_is_released_on_release_all() {
    let mut injector = KeyboardInjector::default();
    let down = injector.plan(&RemoteCommand::KeyDown { key_code: KEY_A, modifiers: Modifiers::NONE });
    assert_eq!(down, vec![key(scan(0x1E, false), false, false)]);
    assert_eq!(injector.release_events(), vec![key(scan(0x1E, false), true, false)]);
    assert!(injector.release_events().is_empty());
}

#[test]
fn a_repeated_key_down_is_released_once() {
    let mut injector = KeyboardInjector::default();
    let command = RemoteCommand::KeyDown { key_code: KEY_A, modifiers: Modifiers::NONE };
    injector.plan(&command);
    injector.plan(&command);
    assert_eq!(injector.release_events().len(), 1);
}

#[test]
fn a_chord_is_released_by_the_key_up_even_when_the_up_carries_no_modifiers() {
    let mut injector = KeyboardInjector::default();
    injector.plan(&RemoteCommand::KeyDown { key_code: C, modifiers: Modifiers::COMMAND });
    let up = injector.plan(&RemoteCommand::KeyUp { key_code: C, modifiers: Modifiers::NONE });
    assert_eq!(up, vec![key(scan(0x2E, false), true, false), key(control(), true, true)]);
    assert!(injector.release_events().is_empty());
}

#[test]
fn a_modifier_the_user_already_holds_is_not_lifted_by_a_chord() {
    let mut injector = KeyboardInjector::default();
    injector.plan(&RemoteCommand::KeyDown { key_code: LEFT_CONTROL, modifiers: Modifiers::NONE });
    let down = injector.plan(&RemoteCommand::KeyDown { key_code: C, modifiers: Modifiers::CONTROL });
    assert_eq!(down, vec![key(scan(0x2E, false), false, false)]);
    let up = injector.plan(&RemoteCommand::KeyUp { key_code: C, modifiers: Modifiers::CONTROL });
    assert_eq!(up, vec![key(scan(0x2E, false), true, false)]);
    assert_eq!(injector.release_events(), vec![key(control(), true, false)]);
}

#[test]
fn a_command_chord_on_command_key_release_lets_go_of_control() {
    let mut injector = KeyboardInjector::default();
    injector.plan(&RemoteCommand::KeyDown { key_code: LEFT_COMMAND, modifiers: Modifiers::NONE });
    let chord_down = injector.plan(&RemoteCommand::KeyDown { key_code: C, modifiers: Modifiers::COMMAND });
    assert_eq!(chord_down, vec![key(scan(0x2E, false), false, false)]);
    let command_up = injector.plan(&RemoteCommand::KeyUp { key_code: LEFT_COMMAND, modifiers: Modifiers::NONE });
    assert_eq!(command_up, vec![key(control(), true, false)]);
}

#[test]
fn release_all_releases_chord_modifiers_and_keys_last_pressed_first() {
    let mut injector = KeyboardInjector::default();
    injector.plan(&RemoteCommand::KeyDown { key_code: KEY_A, modifiers: Modifiers::NONE });
    injector.plan(&RemoteCommand::KeyDown { key_code: C, modifiers: Modifiers::CONTROL });
    let released = injector.release_events();
    assert_eq!(released, vec![key(scan(0x2E, false), true, false), key(control(), true, false), key(scan(0x1E, false), true, false)]);
}

#[test]
fn text_input_is_planned_as_unicode_and_tracks_nothing() {
    let mut injector = KeyboardInjector::default();
    let events = injector.plan(&RemoteCommand::TextInput { text: "a".into() });
    assert_eq!(events.len(), 2);
    assert!(injector.release_events().is_empty());
}

#[test]
fn mouse_commands_produce_no_key_events() {
    let mut injector = KeyboardInjector::default();
    assert!(injector.plan(&RemoteCommand::Scroll { dx: 0.0, dy: 1.0 }).is_empty());
}
