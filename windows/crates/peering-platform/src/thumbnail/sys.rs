//! Screenshots of a window or a display with GDI. Unverified: written against the `windows` 0.58 API and not run on Windows.
//! `PrintWindow` asks the window to draw itself, so one that other windows cover is still photographed whole.

use std::ffi::c_void;
use std::mem::size_of;

use peering_core::ports::thumbnails::{SourceImage, SourceThumbnails};
use peering_wire::source::CaptureSource;
use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC, SelectObject,
    BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT, DIB_RGB_COLORS, HDC, HGDIOBJ, SRCCOPY,
};
use windows::Win32::Storage::Xps::{PrintWindow, PRINT_WINDOW_FLAGS};
use windows::Win32::UI::WindowsAndMessaging::GetWindowRect;

use super::{thumbnail_from, Screenshot};
use crate::monitors::{enumerate_readings, stable_display_id};

/// Asks the window to draw its whole content even when it is not on top, as a window composed by the desktop manager does.
const PW_RENDERFULLCONTENT: PRINT_WINDOW_FLAGS = PRINT_WINDOW_FLAGS(2);

#[derive(Debug, Default)]
pub struct WindowsThumbnails;

impl SourceThumbnails for WindowsThumbnails {
    fn photograph(&self, source: &CaptureSource) -> Option<SourceImage> {
        let (width, height, bgra) = match source {
            CaptureSource::Window { id } => photograph_window(*id)?,
            CaptureSource::Display { id } => photograph_display(*id)?,
            _ => return None,
        };
        let width = u32::try_from(width).ok()?;
        let height = u32::try_from(height).ok()?;
        thumbnail_from(&Screenshot { width, height, bgra: &bgra })
    }
}

fn photograph_window(id: u32) -> Option<(i32, i32, Vec<u8>)> {
    let window = HWND(id as isize as *mut c_void);
    let mut frame = RECT::default();
    // SAFETY: a query on a window handle, which at worst no longer names a window; `frame` is a live local.
    unsafe { GetWindowRect(window, &mut frame).ok()? };
    let (width, height) = (frame.right - frame.left, frame.bottom - frame.top);
    let pixels = shoot(width, height, |canvas| {
        // SAFETY: the window handle and the device context are live for the call.
        unsafe { PrintWindow(window, canvas, PW_RENDERFULLCONTENT).as_bool() }
    })?;
    Some((width, height, pixels))
}

fn photograph_display(id: u32) -> Option<(i32, i32, Vec<u8>)> {
    let reading = enumerate_readings().into_iter().find(|reading| stable_display_id(&reading.device_name) == id)?;
    let (width, height) = (i32::try_from(reading.size_px.0).ok()?, i32::try_from(reading.size_px.1).ok()?);
    let (left, top) = reading.origin_px;
    let pixels = shoot(width, height, |canvas| {
        // SAFETY: the screen's device context is live for the call, and the rectangle is on the virtual desktop.
        unsafe {
            let screen = GetDC(None);
            if screen.is_invalid() {
                return false;
            }
            let copied = BitBlt(canvas, 0, 0, width, height, screen, left, top, SRCCOPY | CAPTUREBLT).is_ok();
            ReleaseDC(None, screen);
            copied
        }
    })?;
    Some((width, height, pixels))
}

/// Runs `draw` on a memory canvas of the given size and reads the pixels back, top row first.
fn shoot(width: i32, height: i32, draw: impl FnOnce(HDC) -> bool) -> Option<Vec<u8>> {
    if width <= 0 || height <= 0 {
        return None;
    }
    let mut header = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..BITMAPINFOHEADER::default()
        },
        ..BITMAPINFO::default()
    };
    let mut pixels = vec![0u8; width as usize * height as usize * 4];
    // SAFETY: every object made here is released before returning, in the reverse order it was made, and `pixels` holds
    // exactly the bytes `GetDIBits` is told to write.
    unsafe {
        let screen = GetDC(None);
        if screen.is_invalid() {
            return None;
        }
        let canvas = CreateCompatibleDC(screen);
        let bitmap = CreateCompatibleBitmap(screen, width, height);
        let previous = SelectObject(canvas, HGDIOBJ(bitmap.0));
        let rows = if draw(canvas) {
            GetDIBits(canvas, bitmap, 0, height as u32, Some(pixels.as_mut_ptr().cast()), &mut header, DIB_RGB_COLORS)
        } else {
            0
        };
        SelectObject(canvas, previous);
        let _bitmap_deleted = DeleteObject(HGDIOBJ(bitmap.0));
        let _canvas_deleted = DeleteDC(canvas);
        ReleaseDC(None, screen);
        (rows > 0).then_some(pixels)
    }
}
