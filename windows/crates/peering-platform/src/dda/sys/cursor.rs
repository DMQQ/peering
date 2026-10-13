//! Draws the pointer into the frames Desktop Duplication delivers. Unverified: written against the `windows` 0.58 API and not
//! run on Windows.
//!
//! The acquired desktop texture belongs to the duplication and is not written to. With the pointer drawn, each frame is a copy
//! of the desktop with the part under the pointer read back, blended on the CPU and written in again. Any failure turns the
//! drawing off for the rest of the capture and the frames go on as they were.

use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11Texture2D, D3D11_BOX, D3D11_CPU_ACCESS_READ, D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_READ, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Dxgi::{IDXGIOutputDuplication, DXGI_OUTDUPL_FRAME_INFO, DXGI_OUTDUPL_POINTER_SHAPE_INFO};

use crate::cursor::{cursor_in_picture, place, CursorShape, PointerState, ShapeKind, MAX_SIDE};
use crate::gpu::GpuContext;

#[derive(Default)]
pub struct CursorLayer {
    pointer: PointerState,
    desktop: Option<ID3D11Texture2D>,
    composed: Option<ID3D11Texture2D>,
    staging: Option<ID3D11Texture2D>,
    failed: bool,
}

impl CursorLayer {
    /// Forgets the pointer and the textures, for a capture that starts again: they belong to the old output and device.
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    fn active(&self) -> bool {
        cursor_in_picture() && !self.failed
    }

    /// Reads what the acquired frame says about the pointer. True when the pointer must be drawn again.
    pub fn observe(&mut self, duplication: &IDXGIOutputDuplication, info: &DXGI_OUTDUPL_FRAME_INFO) -> bool {
        if !self.active() {
            return false;
        }
        let position = (info.LastMouseUpdateTime != 0)
            .then(|| ((info.PointerPosition.Position.x, info.PointerPosition.Position.y), info.PointerPosition.Visible.as_bool()));
        let shape = if info.PointerShapeBufferSize > 0 { read_shape(duplication, info.PointerShapeBufferSize) } else { None };
        self.pointer.update(position, shape)
    }

    /// The texture to encode for this frame, or `None` when there is nothing new to send. Without the pointer drawn that is
    /// the acquired texture itself. `desktop_updated` says the acquired texture holds a new desktop image.
    pub fn texture_for_frame(
        &mut self,
        gpu: &GpuContext,
        acquired: Option<ID3D11Texture2D>,
        desktop_updated: bool,
        pointer_changed: bool,
    ) -> Option<ID3D11Texture2D> {
        if !self.active() {
            return acquired;
        }
        match self.compose(gpu, acquired.as_ref(), desktop_updated, pointer_changed) {
            Ok(texture) => texture,
            Err(_reason) => {
                // The frame that failed is sent as the desktop alone, and so is every later one.
                self.failed = true;
                acquired
            }
        }
    }

    fn compose(
        &mut self,
        gpu: &GpuContext,
        acquired: Option<&ID3D11Texture2D>,
        desktop_updated: bool,
        pointer_changed: bool,
    ) -> windows::core::Result<Option<ID3D11Texture2D>> {
        let refreshed = match (acquired, desktop_updated || self.desktop.is_none()) {
            (Some(acquired), true) => {
                self.copy_desktop(gpu, acquired)?;
                true
            }
            _ => false,
        };
        if !refreshed && !pointer_changed {
            return Ok(None);
        }
        let Some(desktop) = self.desktop.clone() else {
            return Ok(None);
        };
        let Some((shape, (left, top))) = self.pointer.visible() else {
            return Ok(Some(desktop));
        };
        let (shape, left, top) = (shape.clone(), left, top);
        let composed = self.composed_like(gpu, &desktop)?;
        self.draw(gpu, &desktop, &composed, &shape, (left, top))?;
        Ok(Some(composed))
    }

    fn copy_desktop(&mut self, gpu: &GpuContext, acquired: &ID3D11Texture2D) -> windows::core::Result<()> {
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        // SAFETY: `desc` is a live local that GetDesc fills in full.
        unsafe { acquired.GetDesc(&mut desc) };
        if desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM {
            return Err(windows::core::Error::from(windows::Win32::Foundation::E_FAIL));
        }
        let reusable = self.desktop.as_ref().is_some_and(|texture| same_size(texture, &desc));
        if !reusable {
            self.desktop = Some(create_like(&gpu.device, &desc)?);
            self.composed = None;
        }
        if let Some(desktop) = &self.desktop {
            // SAFETY: both textures belong to `gpu`'s device and have the same description.
            unsafe { gpu.context.CopyResource(desktop, acquired) };
        }
        Ok(())
    }

    fn composed_like(&mut self, gpu: &GpuContext, desktop: &ID3D11Texture2D) -> windows::core::Result<ID3D11Texture2D> {
        if self.composed.is_none() {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            // SAFETY: `desc` is a live local that GetDesc fills in full.
            unsafe { desktop.GetDesc(&mut desc) };
            self.composed = Some(create_like(&gpu.device, &desc)?);
        }
        self.composed.clone().ok_or_else(|| windows::core::Error::from(windows::Win32::Foundation::E_FAIL))
    }

    fn draw(
        &mut self,
        gpu: &GpuContext,
        desktop: &ID3D11Texture2D,
        composed: &ID3D11Texture2D,
        shape: &CursorShape,
        at: (i32, i32),
    ) -> windows::core::Result<()> {
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        // SAFETY: `desc` is a live local that GetDesc fills in full.
        unsafe { desktop.GetDesc(&mut desc) };
        // SAFETY: both textures belong to `gpu`'s device and have the same description.
        unsafe { gpu.context.CopyResource(composed, desktop) };
        let Some(placement) = place((desc.Width, desc.Height), (shape.width(), shape.height()), at.0, at.1) else {
            return Ok(());
        };
        let region = D3D11_BOX {
            left: placement.x,
            top: placement.y,
            front: 0,
            right: placement.x + placement.width,
            bottom: placement.y + placement.height,
            back: 1,
        };
        let staging = self.staging_texture(gpu)?;
        let row_bytes = placement.width as usize * 4;
        let mut patch = vec![0u8; row_bytes * placement.height as usize];
        // SAFETY: the box lies inside `desktop` (it was clipped to the frame) and inside the staging texture (the pointer is at
        // most MAX_SIDE on a side). The mapped rows are read within RowPitch of the start, and unmapped before any other use.
        unsafe {
            gpu.context.CopySubresourceRegion(&staging, 0, 0, 0, 0, desktop, 0, Some(&region));
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            gpu.context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
            for row in 0..placement.height as usize {
                let source = std::slice::from_raw_parts(mapped.pData.cast::<u8>().add(row * mapped.RowPitch as usize), row_bytes);
                patch[row * row_bytes..(row + 1) * row_bytes].copy_from_slice(source);
            }
            gpu.context.Unmap(&staging, 0);
        }
        shape.draw(&mut patch, row_bytes, &placement);
        // SAFETY: `patch` holds `placement.height` rows of `row_bytes` for the region, which lies inside `composed`.
        unsafe { gpu.context.UpdateSubresource(composed, 0, Some(&region), patch.as_ptr().cast(), row_bytes as u32, 0) };
        Ok(())
    }

    fn staging_texture(&mut self, gpu: &GpuContext) -> windows::core::Result<ID3D11Texture2D> {
        if self.staging.is_none() {
            let desc = D3D11_TEXTURE2D_DESC {
                Width: MAX_SIDE,
                Height: MAX_SIDE,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: windows::Win32::Graphics::Dxgi::Common::DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            self.staging = Some(create_texture(&gpu.device, &desc)?);
        }
        self.staging.clone().ok_or_else(|| windows::core::Error::from(windows::Win32::Foundation::E_FAIL))
    }
}

fn same_size(texture: &ID3D11Texture2D, desc: &D3D11_TEXTURE2D_DESC) -> bool {
    let mut current = D3D11_TEXTURE2D_DESC::default();
    // SAFETY: `current` is a live local that GetDesc fills in full.
    unsafe { texture.GetDesc(&mut current) };
    current.Width == desc.Width && current.Height == desc.Height && current.Format == desc.Format
}

/// A texture shaped like the duplication's, as a copy target the capture owns.
fn create_like(device: &ID3D11Device, desc: &D3D11_TEXTURE2D_DESC) -> windows::core::Result<ID3D11Texture2D> {
    let mut own = *desc;
    own.MiscFlags = 0;
    create_texture(device, &own)
}

fn create_texture(device: &ID3D11Device, desc: &D3D11_TEXTURE2D_DESC) -> windows::core::Result<ID3D11Texture2D> {
    let mut texture: Option<ID3D11Texture2D> = None;
    // SAFETY: `desc` is a live description and `texture` receives the new interface.
    unsafe { device.CreateTexture2D(desc, None, Some(&mut texture))? };
    texture.ok_or_else(|| windows::core::Error::from(windows::Win32::Foundation::E_FAIL))
}

fn read_shape(duplication: &IDXGIOutputDuplication, size: u32) -> Option<CursorShape> {
    let mut buffer = vec![0u8; size as usize];
    let mut required = 0u32;
    let mut info = DXGI_OUTDUPL_POINTER_SHAPE_INFO::default();
    // SAFETY: `buffer` has `size` writable bytes, and the other two arguments are live locals the call fills in.
    unsafe { duplication.GetFramePointerShape(size, buffer.as_mut_ptr().cast(), &mut required, &mut info) }.ok()?;
    buffer.truncate(required.min(size) as usize);
    CursorShape::new(ShapeKind::from_dxgi(info.Type)?, info.Width, info.Height, info.Pitch, buffer)
}
