//! What a file preview carries, and how much of a file travels. Mirrors the limits in `TerminalSessionManager.swift`.

use peering_wire::files::RemoteFileKind;

use super::vfs::{FileSystem, FsError};

pub const MAXIMUM_TEXT_PREVIEW_BYTES: usize = 128 * 1024;
pub const MAXIMUM_DRAWN_PREVIEW_BYTES: usize = 8 * 1024 * 1024;
/// A video's preview is its header only; the phone fetches the rest by range.
pub const VIDEO_HEADER_BYTES: usize = 8 * 1024;
/// The most a range read returns in one event.
pub const RANGE_CHUNK_BYTES: usize = 32 * 1024;

const SNIFF_BYTES: usize = 8 * 1024;
const MAXIMUM_UTF8_CUT: usize = 3;

pub struct Preview {
    pub data: Vec<u8>,
    pub kind: RemoteFileKind,
    pub total_bytes: i64,
}

pub fn kind_for_name(name: &str) -> Option<RemoteFileKind> {
    let extension = name.rsplit_once('.').map(|(_, extension)| extension.to_ascii_lowercase())?;
    match extension.as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "bmp" | "webp" | "tif" | "tiff" | "ico" | "heic" => {
            Some(RemoteFileKind::Image)
        }
        "svg" => Some(RemoteFileKind::Svg),
        "pdf" => Some(RemoteFileKind::Pdf),
        "mp4" | "mov" | "m4v" => Some(RemoteFileKind::Video),
        _ => None,
    }
}

/// Reads the bounded part of a file the phone may draw. Pictures, PDFs and videos are taken by their name,
/// anything else must decode as UTF-8 text.
pub fn preview(fs: &dyn FileSystem, path: &str, name: &str, total: u64) -> Result<Preview, String> {
    match kind_for_name(name) {
        Some(RemoteFileKind::Video) => drawn(fs, path, total, RemoteFileKind::Video, VIDEO_HEADER_BYTES),
        Some(kind) => drawn(fs, path, total, kind, MAXIMUM_DRAWN_PREVIEW_BYTES),
        None => text(fs, path, total),
    }
}

fn drawn(fs: &dyn FileSystem, path: &str, total: u64, kind: RemoteFileKind, cap: usize) -> Result<Preview, String> {
    let data = fs.read(path, 0, cap).map_err(message)?;
    Ok(Preview {
        data,
        kind,
        total_bytes: as_i64(total),
    })
}

fn text(fs: &dyn FileSystem, path: &str, total: u64) -> Result<Preview, String> {
    let data = fs.read(path, 0, MAXIMUM_TEXT_PREVIEW_BYTES).map_err(message)?;
    if data.iter().take(SNIFF_BYTES).any(|byte| *byte == 0) {
        return Err(NOT_TEXT.to_owned());
    }
    let truncated = total > data.len() as u64;
    let text = decodable_prefix(data, truncated).ok_or_else(|| NOT_TEXT.to_owned())?;
    Ok(Preview {
        data: text,
        kind: RemoteFileKind::Text,
        total_bytes: as_i64(total),
    })
}

/// When the read stopped at the cap, the last character may have been cut. Up to three bytes come off the end
/// before the file is called binary, since a long text file is still text.
fn decodable_prefix(mut data: Vec<u8>, truncated: bool) -> Option<Vec<u8>> {
    let cuts = if truncated { MAXIMUM_UTF8_CUT } else { 0 };
    for _ in 0..=cuts {
        if std::str::from_utf8(&data).is_ok() {
            return Some(data);
        }
        data.pop()?;
    }
    None
}

pub fn message(error: FsError) -> String {
    match error {
        FsError::NotFound => "That is no longer there.".to_owned(),
        FsError::NotADirectory => "Part of that path is not a folder.".to_owned(),
        FsError::NotAFile => NOT_A_FILE.to_owned(),
        FsError::AccessDenied => "Windows did not let Peering read this.".to_owned(),
        FsError::Other(text) => text,
    }
}

pub const NOT_A_FILE: &str = "That is not a file, so there is nothing to show here.";
const NOT_TEXT: &str = "That file is not text or a picture, so there is nothing to show here.";

fn as_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}
