//! macOS virtual keycodes to Windows set 1 scancodes, and the modifier flags applied around a key. See docs/protocol/keymap.md.

/// Outside the macOS keycode range, so it cannot collide with a real key. Only send it to a Windows host.
pub const WINDOWS_KEY_CODE: u16 = 256;

const SHIFT_FLAG: u64 = 1 << 17;
const CONTROL_FLAG: u64 = 1 << 18;
const OPTION_FLAG: u64 = 1 << 19;
const COMMAND_FLAG: u64 = 1 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyTarget {
    pub scancode: u16,
    pub extended: bool,
}

const LEFT_SHIFT: KeyTarget = KeyTarget { scancode: 0x2A, extended: false };
const LEFT_CONTROL: KeyTarget = KeyTarget { scancode: 0x1D, extended: false };
const LEFT_ALT: KeyTarget = KeyTarget { scancode: 0x38, extended: false };

/// (macOS keycode, set 1 make code, E0 prefix). Generated from docs/protocol/vectors/keymap.json.
const KEY_TABLE: &[(u16, u16, bool)] = &[
    (0, 0x1E, false), // a
    (1, 0x1F, false), // s
    (2, 0x20, false), // d
    (3, 0x21, false), // f
    (4, 0x23, false), // h
    (5, 0x22, false), // g
    (6, 0x2C, false), // z
    (7, 0x2D, false), // x
    (8, 0x2E, false), // c
    (9, 0x2F, false), // v
    (11, 0x30, false), // b
    (12, 0x10, false), // q
    (13, 0x11, false), // w
    (14, 0x12, false), // e
    (15, 0x13, false), // r
    (16, 0x15, false), // y
    (17, 0x14, false), // t
    (18, 0x02, false), // 1
    (19, 0x03, false), // 2
    (20, 0x04, false), // 3
    (21, 0x05, false), // 4
    (22, 0x07, false), // 6
    (23, 0x06, false), // 5
    (24, 0x0D, false), // equal
    (25, 0x0A, false), // 9
    (26, 0x08, false), // 7
    (27, 0x0C, false), // minus
    (28, 0x09, false), // 8
    (29, 0x0B, false), // 0
    (30, 0x1B, false), // rightBracket
    (31, 0x18, false), // o
    (32, 0x16, false), // u
    (33, 0x1A, false), // leftBracket
    (34, 0x17, false), // i
    (35, 0x19, false), // p
    (36, 0x1C, false), // return
    (37, 0x26, false), // l
    (38, 0x24, false), // j
    (39, 0x28, false), // quote
    (40, 0x25, false), // k
    (41, 0x27, false), // semicolon
    (42, 0x2B, false), // backslash
    (43, 0x33, false), // comma
    (44, 0x35, false), // slash
    (45, 0x31, false), // n
    (46, 0x32, false), // m
    (47, 0x34, false), // period
    (48, 0x0F, false), // tab
    (49, 0x39, false), // space
    (50, 0x29, false), // grave
    (51, 0x0E, false), // backspace
    (53, 0x01, false), // escape
    (54, 0x1D, true), // rightCommand
    (55, 0x1D, false), // leftCommand
    (56, 0x2A, false), // leftShift
    (57, 0x3A, false), // capsLock
    (58, 0x38, false), // leftOption
    (59, 0x1D, false), // leftControl
    (60, 0x36, false), // rightShift
    (61, 0x38, true), // rightOption
    (62, 0x1D, true), // rightControl
    (65, 0x53, false), // keypadDecimal
    (67, 0x37, false), // keypadMultiply
    (69, 0x4E, false), // keypadPlus
    (75, 0x35, true), // keypadDivide
    (76, 0x1C, true), // keypadEnter
    (78, 0x4A, false), // keypadMinus
    (82, 0x52, false), // keypad0
    (83, 0x4F, false), // keypad1
    (84, 0x50, false), // keypad2
    (85, 0x51, false), // keypad3
    (86, 0x4B, false), // keypad4
    (87, 0x4C, false), // keypad5
    (88, 0x4D, false), // keypad6
    (89, 0x47, false), // keypad7
    (91, 0x48, false), // keypad8
    (92, 0x49, false), // keypad9
    (96, 0x3F, false), // f5
    (97, 0x40, false), // f6
    (98, 0x41, false), // f7
    (99, 0x3D, false), // f3
    (100, 0x42, false), // f8
    (101, 0x43, false), // f9
    (103, 0x57, false), // f11
    (109, 0x44, false), // f10
    (111, 0x58, false), // f12
    (115, 0x47, true), // home
    (116, 0x49, true), // pageUp
    (117, 0x53, true), // forwardDelete
    (118, 0x3E, false), // f4
    (119, 0x4F, true), // end
    (120, 0x3C, false), // f2
    (121, 0x51, true), // pageDown
    (122, 0x3B, false), // f1
    (123, 0x4B, true), // left
    (124, 0x4D, true), // right
    (125, 0x50, true), // down
    (126, 0x48, true), // up
    (256, 0x5B, true), // windowsKey
];

pub fn mac_keycode_to_scancode(mac: u16) -> Option<KeyTarget> {
    KEY_TABLE
        .iter()
        .find(|(code, _, _)| *code == mac)
        .map(|&(_, scancode, extended)| KeyTarget { scancode, extended })
}

/// Command is sent as Ctrl, so Command+C reaches a Windows host as Ctrl+C. Each modifier appears once.
pub fn modifier_keys_for(bits: u64) -> Vec<KeyTarget> {
    let flags = [
        (SHIFT_FLAG, LEFT_SHIFT),
        (CONTROL_FLAG, LEFT_CONTROL),
        (OPTION_FLAG, LEFT_ALT),
        (COMMAND_FLAG, LEFT_CONTROL),
    ];
    let mut keys = Vec::new();
    for (flag, key) in flags {
        if bits & flag != 0 && !keys.contains(&key) {
            keys.push(key);
        }
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;

    fn scancode_entry(entry: &serde_json::Value) -> KeyTarget {
        KeyTarget {
            scancode: entry["scancode"].as_u64().expect("scancode") as u16,
            extended: entry["extended"].as_bool().expect("extended"),
        }
    }

    #[test]
    fn every_key_in_the_vector_maps_to_its_scancode() {
        let vectors = load("keymap.json");
        for (_, entry) in vectors["keys"].as_object().expect("keys object") {
            let mac = entry["mac"].as_u64().expect("mac keycode") as u16;
            assert_eq!(mac_keycode_to_scancode(mac), Some(scancode_entry(entry)), "keycode {mac}");
        }
    }

    #[test]
    fn every_modifier_in_the_vector_maps_to_its_scancode() {
        let vectors = load("keymap.json");
        for (mac, entry) in vectors["modifiers"].as_object().expect("modifiers object") {
            let mac: u16 = mac.parse().expect("modifier keycode");
            assert_eq!(mac_keycode_to_scancode(mac), Some(scancode_entry(entry)), "keycode {mac}");
        }
    }

    #[test]
    fn the_table_holds_exactly_the_vector_entries_and_the_windows_key() {
        let vectors = load("keymap.json");
        let vector_count = vectors["keys"].as_object().expect("keys").len()
            + vectors["modifiers"].as_object().expect("modifiers").len();
        assert_eq!(KEY_TABLE.len(), vector_count + 1);
    }

    #[test]
    fn unknown_keycodes_return_none() {
        assert_eq!(mac_keycode_to_scancode(52), None);
        assert_eq!(mac_keycode_to_scancode(255), None);
    }

    #[test]
    fn windows_key_is_the_left_windows_key() {
        assert_eq!(
            mac_keycode_to_scancode(WINDOWS_KEY_CODE),
            Some(KeyTarget { scancode: 0x5B, extended: true })
        );
    }

    #[test]
    fn no_modifier_bits_press_nothing() {
        assert!(modifier_keys_for(0).is_empty());
    }

    #[test]
    fn command_is_sent_as_left_control() {
        assert_eq!(modifier_keys_for(COMMAND_FLAG), vec![LEFT_CONTROL]);
    }

    #[test]
    fn command_and_control_give_one_control_key() {
        assert_eq!(modifier_keys_for(COMMAND_FLAG | CONTROL_FLAG), vec![LEFT_CONTROL]);
    }

    #[test]
    fn modifiers_keep_shift_control_option_order() {
        let all = SHIFT_FLAG | CONTROL_FLAG | OPTION_FLAG | COMMAND_FLAG;
        assert_eq!(modifier_keys_for(all), vec![LEFT_SHIFT, LEFT_CONTROL, LEFT_ALT]);
    }
}
