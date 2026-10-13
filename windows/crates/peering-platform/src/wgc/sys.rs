//! Windows.Graphics.Capture of one window into D3D11 textures. Unverified: written against the `windows` 0.58 API and not run
//! on Windows.
//!
//! Frames are copied out of the pool's surface at once into a texture this capture owns, so the pool can reuse its buffers and
//! the encoder can take the copy later, as it takes the duplication's frames.

use windows::core::Interface;
use windows::Foundation::IClosable;
use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureSession};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Graphics::SizeInt32;
use windows::Win32::Foundation::{E_FAIL, HMODULE, HWND};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_HARDWARE;
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_BOX, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Dxgi::IDXGIDevice;
use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};
use windows::Win32::UI::WindowsAndMessaging::IsWindow;

use peering_core::ports::capture::CaptureError;

use super::pool_needs_recreating;
use crate::gpu::GpuContext;
use crate::handoff::FrameHandoff;
use crate::window_list::create_item;

/// Two buffers: one being read while the next is drawn.
const BUFFERS: i32 = 2;

struct Running {
    window: u32,
    device: IDirect3DDevice,
    pool: Direct3D11CaptureFramePool,
    session: GraphicsCaptureSession,
    pool_size: (u32, u32),
}

#[derive(Default)]
pub struct WindowCapture {
    gpu: Option<GpuContext>,
    running: Option<Running>,
    copy: Option<ID3D11Texture2D>,
    captured: Option<FrameHandoff<ID3D11Texture2D>>,
    sequence: u64,
}

// SAFETY: the capture and its D3D11 objects are used from one thread at a time, the one the host moves the capture to before
// use; see `SharedLink` in `services.rs`.
unsafe impl Send for WindowCapture {}

impl WindowCapture {
    /// The device frames are copied on. `reuse` is the duplication's, so the encoder keeps its device when the picture moves
    /// between a screen and a window; without one a device is made on the default adapter.
    pub fn start(&mut self, window: u32, reuse: Option<GpuContext>) -> Result<(), CaptureError> {
        self.stop();
        let failed = |error: windows::core::Error| CaptureError::Failed(error.to_string());
        // SAFETY: initialising the Windows Runtime for this thread; a thread that is already initialised answers S_FALSE.
        let _initialised = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
        let gpu = match reuse.or_else(|| self.gpu.take()) {
            Some(gpu) => gpu,
            None => create_gpu().map_err(failed)?,
        };
        let item = create_item(window).ok_or(CaptureError::WindowNotFound(window))?;
        let size = item.Size().map_err(failed)?;
        let device = winrt_device(&gpu).map_err(failed)?;
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&device, DirectXPixelFormat::B8G8R8A8UIntNormalized, BUFFERS, size).map_err(failed)?;
        let session = pool.CreateCaptureSession(&item).map_err(failed)?;
        // The cursor is drawn into the window by the capture itself. A border the system draws around a captured window can be
        // switched off only on newer builds, so a refusal is not a failure.
        let _cursor = session.SetIsCursorCaptureEnabled(true);
        let _border = session.SetIsBorderRequired(false);
        session.StartCapture().map_err(failed)?;
        self.gpu = Some(gpu);
        self.running = Some(Running { window, device, pool, session, pool_size: (size.Width.max(0) as u32, size.Height.max(0) as u32) });
        self.sequence = 0;
        Ok(())
    }

    pub fn stop(&mut self) {
        if let Some(running) = self.running.take() {
            // A session or pool that is already closed answers an error, which is the outcome asked for.
            let _session = running.session.cast::<IClosable>().and_then(|closable| closable.Close());
            let _pool = running.pool.cast::<IClosable>().and_then(|closable| closable.Close());
        }
        self.copy = None;
        self.captured = None;
    }

    pub fn gpu(&self) -> Option<GpuContext> {
        self.gpu.clone()
    }

    pub fn is_running(&self) -> bool {
        self.running.is_some()
    }

    /// True once the window is gone: nothing more will come from it.
    pub fn has_failed(&self) -> bool {
        // SAFETY: a plain query on a window handle, which at worst no longer names a window.
        self.running.as_ref().is_some_and(|running| !unsafe { IsWindow(HWND(running.window as usize as *mut core::ffi::c_void)) }.as_bool())
    }

    pub fn probe(&self) -> Result<(), CaptureError> {
        if self.has_failed() {
            return Err(CaptureError::Failed("the window is gone".to_owned()));
        }
        Ok(())
    }

    /// The texture of the frame `poll_frame` last returned, with its sequence.
    pub fn take_captured(&mut self) -> Option<FrameHandoff<ID3D11Texture2D>> {
        self.captured.take()
    }

    /// The newest frame the window drew since the last call, copied out of the pool. Frames drawn in between are not wanted.
    pub fn poll_frame(&mut self) -> Option<(u32, u32, u64)> {
        let gpu = self.gpu.clone()?;
        let running = self.running.as_mut()?;
        let mut newest = None;
        while let Ok(frame) = running.pool.TryGetNextFrame() {
            if let Some(older) = newest.replace(frame) {
                let _released = older.cast::<IClosable>().and_then(|closable| closable.Close());
            }
        }
        let frame = newest?;
        let copied = copy_frame(&gpu, &frame, running, &mut self.copy);
        let _released = frame.cast::<IClosable>().and_then(|closable| closable.Close());
        let (texture, width, height) = copied?;
        self.sequence += 1;
        self.captured = Some(FrameHandoff { sequence: self.sequence, width, height, texture });
        Some((width, height, self.sequence))
    }
}

impl Drop for WindowCapture {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Copies the part of the frame the window filled into a texture of exactly that size, and makes the pool follow a resize.
fn copy_frame(
    gpu: &GpuContext,
    frame: &windows::Graphics::Capture::Direct3D11CaptureFrame,
    running: &mut Running,
    copy: &mut Option<ID3D11Texture2D>,
) -> Option<(ID3D11Texture2D, u32, u32)> {
    let content = frame.ContentSize().ok()?;
    let (width, height) = (content.Width.max(0) as u32, content.Height.max(0) as u32);
    if width == 0 || height == 0 {
        return None;
    }
    let access: IDirect3DDxgiInterfaceAccess = frame.Surface().ok()?.cast().ok()?;
    // SAFETY: the surface is a D3D11 texture on the device the pool was made with.
    let source: ID3D11Texture2D = unsafe { access.GetInterface() }.ok()?;
    let mut description = D3D11_TEXTURE2D_DESC::default();
    // SAFETY: `description` is a live local that GetDesc fills in full.
    unsafe { source.GetDesc(&mut description) };
    if description.Format != DXGI_FORMAT_B8G8R8A8_UNORM {
        return None;
    }
    let reusable = copy.as_ref().is_some_and(|texture| {
        let mut own = D3D11_TEXTURE2D_DESC::default();
        // SAFETY: `own` is a live local that GetDesc fills in full.
        unsafe { texture.GetDesc(&mut own) };
        own.Width == width && own.Height == height
    });
    if !reusable {
        let mut wanted = description;
        wanted.Width = width;
        wanted.Height = height;
        wanted.MiscFlags = 0;
        let mut texture: Option<ID3D11Texture2D> = None;
        // SAFETY: `wanted` is a live description and `texture` receives the new interface.
        unsafe { gpu.device.CreateTexture2D(&wanted, None, Some(&mut texture)) }.ok()?;
        *copy = texture;
    }
    let target = copy.clone()?;
    let region = D3D11_BOX { left: 0, top: 0, front: 0, right: width.min(description.Width), bottom: height.min(description.Height), back: 1 };
    // SAFETY: both textures belong to `gpu`'s device, and the region lies inside the source.
    unsafe { gpu.context.CopySubresourceRegion(&target, 0, 0, 0, 0, &source, 0, Some(&region)) };
    if pool_needs_recreating(running.pool_size, (width, height)) {
        let size = SizeInt32 { Width: content.Width, Height: content.Height };
        if running.pool.Recreate(&running.device, DirectXPixelFormat::B8G8R8A8UIntNormalized, BUFFERS, size).is_ok() {
            running.pool_size = (width, height);
        }
    }
    Some((target, width, height))
}

fn winrt_device(gpu: &GpuContext) -> windows::core::Result<IDirect3DDevice> {
    let dxgi: IDXGIDevice = gpu.device.cast()?;
    // SAFETY: `dxgi` is the live DXGI view of the device.
    unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi) }?.cast()
}

fn create_gpu() -> windows::core::Result<GpuContext> {
    let mut device: Option<ID3D11Device> = None;
    let mut context: Option<ID3D11DeviceContext> = None;
    // SAFETY: the default hardware adapter with BGRA support, which capture textures need; the out pointers are live locals.
    unsafe {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )?;
    }
    let device = device.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    let context = context.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    let dxgi: IDXGIDevice = device.cast()?;
    // SAFETY: plain queries on the live DXGI device and its adapter.
    let luid = unsafe { dxgi.GetAdapter()?.GetDesc()? }.AdapterLuid;
    Ok(GpuContext::new(device, context, luid))
}
