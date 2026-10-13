//! The PC's keyboard focus through UI Automation, on a thread of its own because a program that has stopped answering holds a
//! UI Automation call for seconds. What counts as a text field, and where the caret is, are pure and tested on any OS;
//! `focus/sys.rs` makes the calls.

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::UiaFocus;

/// `UIA_ControlTypeIds`.
const COMBO_BOX: i32 = 50003;
const EDIT: i32 = 50004;
const DOCUMENT: i32 = 50030;

/// What an element offers, as far as deciding whether it takes typing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ElementTraits {
    pub control_type: i32,
    /// `Some(false)` for a value that can be changed, `Some(true)` for one that cannot, `None` for an element with no value.
    pub value_read_only: Option<bool>,
}

/// Whether typing goes into the element. A plain edit takes it unless it says it is read only. A document (a web page, or a
/// rich text editor) and a combo box take it only when they report a value that can be changed, because a page as a whole
/// has the focus whenever no field does.
pub fn takes_typing(element: ElementTraits) -> bool {
    match element.control_type {
        EDIT => element.value_read_only != Some(true),
        DOCUMENT | COMBO_BOX => element.value_read_only == Some(false),
        _ => false,
    }
}

/// Programs whose text area is the whole screen of a shell, which is no use to mirror in a phone's text field.
const TERMINAL_PROGRAMS: [&str; 7] = ["windowsterminal.exe", "conhost.exe", "openconsole.exe", "cmd.exe", "powershell.exe", "pwsh.exe", "wezterm-gui.exe"];

/// `image` is a program's file name or full path.
pub fn is_terminal_program(image: &str) -> bool {
    let name = image.rsplit(['\\', '/']).next().unwrap_or(image).to_ascii_lowercase();
    TERMINAL_PROGRAMS.contains(&name.as_str())
}

/// The middle of the first rectangle that has a height, from UI Automation's flat `left, top, width, height` lists, else the
/// middle of the element's own rectangle. Both in desktop pixels.
pub fn caret_point(text_rectangles: &[f64], element_rectangle: Option<[f64; 4]>) -> Option<(f64, f64)> {
    let middle = |rectangle: &[f64]| -> Option<(f64, f64)> {
        let [left, top, width, height] = rectangle else { return None };
        ([left, top, width, height].iter().all(|value| value.is_finite()) && *height > 0.0).then(|| (left + width / 2.0, top + height / 2.0))
    };
    text_rectangles.chunks_exact(4).find_map(middle).or_else(|| element_rectangle.and_then(|rectangle| middle(&rectangle)))
}

/// UTF-16 length of text, or `None` when it is longer than `limit` and so was cut short.
pub fn utf16_length_within(text: &str, limit: usize) -> Option<u32> {
    let length = text.encode_utf16().count();
    (length <= limit).then_some(length as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn traits(control_type: i32, value_read_only: Option<bool>) -> ElementTraits {
        ElementTraits { control_type, value_read_only }
    }

    #[test]
    fn an_edit_takes_typing_unless_it_is_read_only() {
        assert!(takes_typing(traits(EDIT, None)));
        assert!(takes_typing(traits(EDIT, Some(false))));
        assert!(!takes_typing(traits(EDIT, Some(true))));
    }

    #[test]
    fn a_page_takes_typing_only_when_it_reports_an_editable_value() {
        assert!(!takes_typing(traits(DOCUMENT, None)), "a web page as a whole");
        assert!(!takes_typing(traits(DOCUMENT, Some(true))));
        assert!(takes_typing(traits(DOCUMENT, Some(false))), "a rich text editor");
        assert!(takes_typing(traits(COMBO_BOX, Some(false))));
        assert!(!takes_typing(traits(COMBO_BOX, None)), "a drop down list");
    }

    #[test]
    fn buttons_and_labels_do_not_take_typing() {
        for control_type in [50000, 50020, 50025, 50033] {
            assert!(!takes_typing(traits(control_type, Some(false))), "{control_type}");
        }
    }

    #[test]
    fn terminals_are_known_by_file_name() {
        assert!(is_terminal_program("C:\\Program Files\\WindowsApps\\WindowsTerminal.exe"));
        assert!(is_terminal_program("pwsh.exe"));
        assert!(is_terminal_program("C:/Windows/System32/CMD.EXE"));
        assert!(!is_terminal_program("C:\\Windows\\notepad.exe"));
        assert!(!is_terminal_program("code.exe"));
    }

    #[test]
    fn the_caret_is_the_middle_of_the_first_rectangle_with_a_height() {
        let rectangles = [10.0, 20.0, 0.0, 0.0, 100.0, 200.0, 4.0, 18.0];
        assert_eq!(caret_point(&rectangles, None), Some((102.0, 209.0)));
    }

    #[test]
    fn with_no_text_rectangle_the_element_stands_in() {
        assert_eq!(caret_point(&[], Some([0.0, 0.0, 200.0, 40.0])), Some((100.0, 20.0)));
        assert_eq!(caret_point(&[], Some([0.0, 0.0, 200.0, 0.0])), None);
        assert_eq!(caret_point(&[], None), None);
    }

    #[test]
    fn a_torn_or_non_finite_rectangle_gives_no_caret() {
        assert_eq!(caret_point(&[1.0, 2.0, 3.0], None), None);
        assert_eq!(caret_point(&[f64::NAN, 0.0, 1.0, 1.0], None), None);
        assert_eq!(caret_point(&[0.0, 0.0, f64::INFINITY, 5.0], None), None);
    }

    #[test]
    fn text_longer_than_the_limit_has_no_known_length() {
        assert_eq!(utf16_length_within("abc", 3), Some(3));
        assert_eq!(utf16_length_within("abcd", 3), None);
        assert_eq!(utf16_length_within("\u{1F600}", 3), Some(2));
    }
}
