//! The wire's POSIX shaped paths as Windows paths. `/` is the list of drives, `/C:/Users/me` is `C:\Users\me`.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VirtualPath {
    Drives,
    /// A Windows path, such as `C:\` or `C:\Users\me`.
    Native(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidPath;

/// Refuses anything that is not absolute or that would step out of the drive it names.
pub fn parse(virtual_path: &str) -> Result<VirtualPath, InvalidPath> {
    let rest = virtual_path.strip_prefix('/').ok_or(InvalidPath)?;
    let segments: Vec<&str> = rest.split('/').filter(|segment| !segment.is_empty()).collect();
    let Some((drive, below)) = segments.split_first() else {
        return Ok(VirtualPath::Drives);
    };
    if !is_drive(drive) || !below.iter().all(|segment| is_name(segment)) {
        return Err(InvalidPath);
    }
    Ok(VirtualPath::Native(format!("{drive}\\{}", below.join("\\"))))
}

/// The wire form of a Windows path. Drive roots keep their colon: `C:\` is `/C:`.
pub fn virtual_of(native: &str) -> String {
    format!("/{}", native.trim_end_matches('\\').replace('\\', "/"))
}

fn is_drive(segment: &str) -> bool {
    let mut characters = segment.chars();
    matches!(
        (characters.next(), characters.next(), characters.next()),
        (Some(letter), Some(':'), None) if letter.is_ascii_alphabetic()
    )
}

/// A single name below a drive. `.` and `..` would move the path, a backslash would add a level the wire did not
/// name, and a reserved device name or a trailing dot or space would open a device instead of a file.
fn is_name(segment: &str) -> bool {
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
            assert_eq!(parse(&format!("/C:/{name}")), Err(InvalidPath), "{name}");
        }
    }

    #[test]
    fn names_that_only_resemble_devices_are_kept() {
        for name in ["console", "com10", "com", "lpt", "auxiliary.txt", "nullable"] {
            assert!(parse(&format!("/C:/{name}")).is_ok(), "{name}");
        }
    }

    #[test]
    fn trailing_dots_and_spaces_and_wildcards_are_refused() {
        for name in ["file.", "file ", "a*b", "a?b", "a<b", "a|b", "a\"b"] {
            assert_eq!(parse(&format!("/C:/Users/{name}")), Err(InvalidPath), "{name}");
        }
    }

    #[test]
    fn a_device_name_below_a_folder_is_refused() {
        assert_eq!(parse("/C:/Users/me/nul"), Err(InvalidPath));
    }
}
