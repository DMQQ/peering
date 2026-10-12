//! Which names may appear below a drive in a path a phone sends. Shared by every folder browser on the host.

/// A single name below a drive. `.` and `..` would move the path, a backslash would add a level the wire did not
/// name, and a reserved device name or a trailing dot or space would open a device instead of a file.
pub fn is_name(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && !segment.contains(['\\', ':', '\0', '<', '>', '"', '|', '?', '*'])
        && !segment.ends_with(['.', ' '])
        && !is_device_name(segment)
}

/// Windows resolves `con`, `con.txt` and `CON .txt` to the console: the device name is the part before the first dot,
/// ignoring case and trailing spaces.
fn is_device_name(segment: &str) -> bool {
    let stem = segment.split('.').next().unwrap_or(segment).trim_end_matches(' ').to_ascii_uppercase();
    match stem.as_str() {
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$" => true,
        _ => ["COM", "LPT"].iter().any(|prefix| {
            stem.strip_prefix(prefix).is_some_and(|number| {
                matches!(number, "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "\u{b9}" | "\u{b2}" | "\u{b3}")
            })
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reserved_device_names_are_refused_with_or_without_an_extension() {
        for name in ["con", "CON", "con.txt", "Nul.tar.gz", "aux", "PRN", "com1", "LPT9", "com0", "COM\u{b9}", "CONIN$", "con .txt"] {
            assert!(!is_name(name), "{name}");
        }
    }

    #[test]
    fn names_that_only_resemble_devices_are_kept() {
        for name in ["console", "com10", "com", "lpt", "auxiliary.txt", "nullable"] {
            assert!(is_name(name), "{name}");
        }
    }

    #[test]
    fn trailing_dots_and_spaces_and_wildcards_are_refused() {
        for name in ["file.", "file ", "a*b", "a?b", "a<b", "a|b", "a\"b"] {
            assert!(!is_name(name), "{name}");
        }
    }

    #[test]
    fn steps_out_of_the_folder_and_separators_are_refused() {
        for name in ["", ".", "..", "a\\b", "C:x"] {
            assert!(!is_name(name), "{name:?}");
        }
    }
}
