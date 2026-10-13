//! The wire's POSIX shaped paths as Windows paths, the same rules as `peering-core`'s file browser.
//! `/` is the list of drives, `/C:/Users/me` is `C:\Users\me`.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VirtualPath {
    Drives,
    Native(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidPath;

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

fn is_name(segment: &str) -> bool {
    peering_wire::path_segment::is_name(segment)
}
