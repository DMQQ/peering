//! The clipboard calls. Unverified: written against the `windows` 0.58 API and not run on Windows.

use std::time::Duration;

use peering_core::ports::clipboard::{Clipboard, ClipboardContent, ClipboardError};
use peering_wire::clipboard::MAX_IMAGE_BYTES;
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL, HINSTANCE, HWND};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::{CF_DIB, CF_DIBV5, CF_UNICODETEXT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DestroyWindow, HMENU, HWND_MESSAGE, WINDOW_EX_STYLE, WINDOW_STYLE,
};

use super::{text_from_utf16, utf16_with_terminator};
use crate::clipboard_image::{dib_to_png, png_to_dib};

/// Another program holding the clipboard open lets go within a few milliseconds, or is stuck.
const OPEN_ATTEMPTS: u32 = 10;
const OPEN_RETRY: Duration = Duration::from_millis(10);

#[derive(Debug, Default, Clone, Copy)]
pub struct WindowsClipboard;

/// The clipboard, open for this thread until dropped.
struct Opened;

impl Drop for Opened {
    fn drop(&mut self) {
        // SAFETY: the clipboard was opened by this thread, and closing it again is the only thing left to do with it.
        let _closed = unsafe { CloseClipboard() };
    }
}

fn open(owner: HWND) -> Result<Opened, ClipboardError> {
    for attempt in 0..OPEN_ATTEMPTS {
        // SAFETY: OpenClipboard takes a window handle that is null or live, which `owner` is.
        if unsafe { OpenClipboard(owner) }.is_ok() {
            return Ok(Opened);
        }
        if attempt + 1 < OPEN_ATTEMPTS {
            std::thread::sleep(OPEN_RETRY);
        }
    }
    Err(ClipboardError::Busy)
}

impl Clipboard for WindowsClipboard {
    fn read(&self, allow_image: bool) -> Result<ClipboardContent, ClipboardError> {
        let _opened = open(HWND::default())?;
        let mut format = 0u32;
        loop {
            // SAFETY: the clipboard is open; passing the previous format (or zero) is how the list is walked.
            format = unsafe { EnumClipboardFormats(format) };
            if format == 0 {
                return Ok(ClipboardContent::Empty);
            }
            if format == u32::from(CF_UNICODETEXT.0) {
                if let Some(bytes) = copy_global(format) {
                    return Ok(ClipboardContent::Text(text_from_utf16(&units_of(&bytes))));
                }
            } else if allow_image && (format == u32::from(CF_DIBV5.0) || format == u32::from(CF_DIB.0)) {
                if let Some(png) = copy_global(format).and_then(|dib| dib_to_png(&dib)) {
                    return Ok(ClipboardContent::Image(png));
                }
            }
        }
    }

    fn write(&self, content: &ClipboardContent) -> Result<(), ClipboardError> {
        match content {
            ClipboardContent::Empty => Ok(()),
            ClipboardContent::Text(text) => {
                let units = utf16_with_terminator(text);
                let bytes: Vec<u8> = units.iter().flat_map(|unit| unit.to_le_bytes()).collect();
                replace_with(u32::from(CF_UNICODETEXT.0), &bytes)
            }
            ClipboardContent::Image(png) => {
                let dib = png_to_dib(png).ok_or_else(|| ClipboardError::Failed("the picture could not be decoded".to_owned()))?;
                replace_with(u32::from(CF_DIBV5.0), &dib)
            }
        }
    }
}

fn units_of(bytes: &[u8]) -> Vec<u16> {
    bytes.chunks_exact(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]])).collect()
}

/// A copy of the global block the clipboard holds for `format`, or `None` when it cannot be read or is too large to carry.
fn copy_global(format: u32) -> Option<Vec<u8>> {
    // SAFETY: the clipboard is open, so the handle it returns stays valid until it is closed.
    let handle = unsafe { GetClipboardData(format) }.ok()?;
    let block = HGLOBAL(handle.0);
    // SAFETY: `block` is the global block of the clipboard entry; it is locked for the copy and unlocked after.
    unsafe {
        let size = GlobalSize(block);
        if size == 0 || size > MAX_IMAGE_BYTES * 8 {
            return None;
        }
        let pointer = GlobalLock(block).cast::<u8>();
        if pointer.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(pointer, size).to_vec();
        // Unlocking a block that was locked once reports an error only when the lock count was already zero.
        let _unlocked = GlobalUnlock(block);
        Some(bytes)
    }
}

/// Empties the clipboard and puts `bytes` there as `format`. The window is only the owner SetClipboardData requires: the data
/// is handed over whole, so it outlives the window.
fn replace_with(format: u32, bytes: &[u8]) -> Result<(), ClipboardError> {
    let owner = OwnerWindow::create()?;
    let _opened = open(owner.0)?;
    // SAFETY: the clipboard is open with a live owner.
    unsafe { EmptyClipboard() }.map_err(|error| ClipboardError::Failed(error.to_string()))?;
    // SAFETY: GlobalAlloc with GMEM_MOVEABLE returns a block the clipboard can take.
    let block = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes.len()) }.map_err(|error| ClipboardError::Failed(error.to_string()))?;
    // SAFETY: `block` was just allocated with `bytes.len()` bytes and is locked while they are copied in.
    let filled = unsafe {
        let pointer = GlobalLock(block).cast::<u8>();
        if pointer.is_null() {
            false
        } else {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer, bytes.len());
            let _unlocked = GlobalUnlock(block);
            true
        }
    };
    if !filled {
        // SAFETY: the block was never handed to the clipboard, so it is still ours to free.
        let _freed = unsafe { GlobalFree(block) };
        return Err(ClipboardError::Failed("the memory for the clipboard could not be locked".to_owned()));
    }
    // SAFETY: on success the clipboard owns `block`; on failure it is still ours and is freed below.
    match unsafe { SetClipboardData(format, HANDLE(block.0)) } {
        Ok(_) => Ok(()),
        Err(error) => {
            // SAFETY: SetClipboardData failed, so the block was not taken.
            let _freed = unsafe { GlobalFree(block) };
            Err(ClipboardError::Failed(error.to_string()))
        }
    }
}

/// A hidden message-only window, destroyed on drop.
struct OwnerWindow(HWND);

impl OwnerWindow {
    fn create() -> Result<Self, ClipboardError> {
        // SAFETY: the predefined STATIC class needs no registration, and a message-only window shows nothing.
        let window = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                windows::core::w!("STATIC"),
                windows::core::PCWSTR::null(),
                WINDOW_STYLE(0),
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                HMENU::default(),
                HINSTANCE::default(),
                None,
            )
        }
        .map_err(|error| ClipboardError::Failed(error.to_string()))?;
        Ok(Self(window))
    }
}

impl Drop for OwnerWindow {
    fn drop(&mut self) {
        // SAFETY: the window was created by `create` on this thread and is destroyed once.
        let _destroyed = unsafe { DestroyWindow(self.0) };
    }
}
