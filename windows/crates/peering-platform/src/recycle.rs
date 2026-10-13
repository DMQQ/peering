//! Moving a file or folder to the Recycle Bin, so a delete from the phone can be undone on the PC. The decisions are pure and
//! tested on any OS; the shell call lives in `recycle/sys.rs`.

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::WindowsRecycleBin;

/// `DRIVE_FIXED`: a disk inside the PC. Removable and network drives have no Recycle Bin of their own, and the shell would
/// delete from them for good.
const DRIVE_FIXED: u32 = 3;

pub fn bin_exists_for(drive_type: u32) -> bool {
    drive_type == DRIVE_FIXED
}

/// The path as the shell wants it: UTF-16 and ended by two zeros, because the shell takes a list of paths.
pub fn path_list(path: &str) -> Vec<u16> {
    path.encode_utf16().chain([0, 0]).collect()
}

/// `C:\` for a path on drive C, which is what a drive type is asked about.
pub fn drive_root(path: &str) -> Option<String> {
    let mut characters = path.chars();
    match (characters.next(), characters.next()) {
        (Some(letter), Some(':')) if letter.is_ascii_alphabetic() => Some(format!("{letter}:\\")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_fixed_drive_has_a_recycle_bin_to_use() {
        assert!(bin_exists_for(3));
        for other in [0, 1, 2, 4, 5, 6] {
            assert!(!bin_exists_for(other), "{other}");
        }
    }

    #[test]
    fn the_path_list_ends_with_two_zeros() {
        assert_eq!(path_list("C:\\a"), [67, 58, 92, 97, 0, 0]);
    }

    #[test]
    fn a_drive_root_is_taken_from_the_letter() {
        assert_eq!(drive_root("d:\\Data\\x").as_deref(), Some("d:\\"));
        assert_eq!(drive_root("\\\\server\\share"), None);
        assert_eq!(drive_root("relative"), None);
    }
}
