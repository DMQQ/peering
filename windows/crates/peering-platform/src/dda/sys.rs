//! The DXGI duplication loop behind `Capture`. Frame textures stay on the GPU until the encoder takes them.

mod open;

use std::time::Instant;

use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};
use windows::core::{Interface, HRESULT};
use windows::Win32::Graphics::Direct3D11::{ID3D11Texture2D, D3D11_TEXTURE2D_DESC};
use windows::Win32::Graphics::Dxgi::{
    IDXGIOutputDuplication, IDXGIResource, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
};

use crate::dda::{classify, CaptureState, Classification, HresultKind};
use crate::gpu::GpuContext;
use crate::handoff::FrameHandoff;
use crate::monitors;
use open::open_duplication;

const ACQUIRE_TIMEOUT_MS: u32 = 2;

// SAFETY: the duplication and its device are used from one thread only, the one the host moves the capture to before use;
// see `SharedLink` in `services.rs`.
unsafe impl Send for DesktopDuplicationCapture {}

pub struct DesktopDuplicationCapture {
    started: Instant,
    state: CaptureState,
    target_device_name: Option<String>,
    gpu: Option<GpuContext>,
    duplication: Option<IDXGIOutputDuplication>,
    frame_held: bool,
    captured: Option<FrameHandoff<ID3D11Texture2D>>,
    sequence: u64,
}

impl Default for DesktopDuplicationCapture {
    fn default() -> Self {
        Self::new()
    }
}

impl DesktopDuplicationCapture {
    pub fn new() -> Self {
        Self {
            started: Instant::now(),
            state: CaptureState::Idle,
            target_device_name: None,
            gpu: None,
            duplication: None,
            frame_held: false,
            captured: None,
            sequence: 0,
        }
    }

    /// The texture of the frame `poll_frame` last returned, with its sequence. It is valid until the next `poll_frame`,
    /// which releases the desktop frame it came from, so the consumer converts it before polling again.
    pub fn take_captured(&mut self) -> Option<FrameHandoff<ID3D11Texture2D>> {
        self.captured.take()
    }

    /// The device the duplication runs on. It is kept across stops, so a restart on the same adapter reuses it.
    pub fn gpu(&self) -> Option<GpuContext> {
        self.gpu.clone()
    }

    pub fn access_losses(&self) -> u32 {
        self.state.losses()
    }

    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    fn release_frame(&mut self) {
        self.captured = None;
        if std::mem::take(&mut self.frame_held) {
            if let Some(duplication) = &self.duplication {
                // SAFETY: `frame_held` means a frame was acquired on this duplication and not yet released.
                let _ = unsafe { duplication.ReleaseFrame() };
            }
        }
    }

    fn reacquire(&mut self, now: f64) {
        let Some(device_name) = self.target_device_name.clone() else {
            return;
        };
        match open_duplication(&device_name, self.gpu.as_ref()) {
            Ok((gpu, duplication)) => {
                self.gpu = Some(gpu);
                self.duplication = Some(duplication);
                self.state.reacquired();
            }
            Err(_) => self.state.reacquire_failed(now),
        }
    }

    fn acquire(&mut self, now: f64) -> Option<RawFrame> {
        let duplication = self.duplication.as_ref()?;
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource: Option<IDXGIResource> = None;
        // SAFETY: both out pointers are live locals; `poll_frame` releases any earlier frame before calling this.
        let result = unsafe { duplication.AcquireNextFrame(ACQUIRE_TIMEOUT_MS, &mut info, &mut resource) };
        match result {
            Ok(()) => {
                self.frame_held = true;
                self.on_acquired(resource)
            }
            Err(error) => {
                self.on_acquire_error(kind_of(error.code()), now);
                None
            }
        }
    }

    /// A frame with no desktop image only moved the pointer. It still has to be released, and it is not a new frame.
    fn on_acquired(&mut self, resource: Option<IDXGIResource>) -> Option<RawFrame> {
        let texture = resource.and_then(|resource| resource.cast::<ID3D11Texture2D>().ok());
        let Some(texture) = texture else {
            self.release_frame();
            return None;
        };
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        // SAFETY: `desc` is a live local that GetDesc fills in full.
        unsafe { texture.GetDesc(&mut desc) };
        self.sequence += 1;
        self.state.frame_arrived();
        let frame = RawFrame { width: desc.Width, height: desc.Height, sequence: self.sequence };
        self.captured = Some(FrameHandoff {
            sequence: frame.sequence,
            width: frame.width,
            height: frame.height,
            texture,
        });
        Some(frame)
    }

    fn on_acquire_error(&mut self, kind: HresultKind, now: f64) {
        match classify(kind) {
            Classification::NewFrame | Classification::NoNewFrame => {}
            Classification::AccessLost => {
                self.duplication = None;
                self.state.access_lost(now);
            }
            Classification::Fatal => {
                self.duplication = None;
                self.state.fail();
            }
        }
    }
}

fn kind_of(code: HRESULT) -> HresultKind {
    if code == DXGI_ERROR_WAIT_TIMEOUT {
        HresultKind::WaitTimeout
    } else if code == DXGI_ERROR_ACCESS_LOST {
        HresultKind::AccessLost
    } else {
        HresultKind::Other
    }
}

fn device_name_for(display_id: u32) -> Option<String> {
    monitors::enumerate_readings()
        .into_iter()
        .find(|reading| monitors::stable_display_id(&reading.device_name) == display_id)
        .map(|reading| reading.device_name)
}

impl Capture for DesktopDuplicationCapture {
    fn list_displays(&self) -> Vec<DisplayInfo> {
        monitors::enumerate_monitors()
    }

    fn start(&mut self, display_id: u32) -> Result<(), CaptureError> {
        self.stop();
        let device_name = device_name_for(display_id).ok_or(CaptureError::DisplayNotFound(display_id))?;
        match open_duplication(&device_name, self.gpu.as_ref()) {
            Ok((gpu, duplication)) => {
                self.gpu = Some(gpu);
                self.duplication = Some(duplication);
                self.target_device_name = Some(device_name);
                self.state.start();
                Ok(())
            }
            Err(error) => {
                self.state.fail();
                Err(CaptureError::Failed(error.to_string()))
            }
        }
    }

    fn stop(&mut self) {
        self.release_frame();
        self.duplication = None;
        self.target_device_name = None;
        self.state.stop();
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        let now = self.now();
        self.release_frame();
        if self.state.reacquire_due(now) {
            self.reacquire(now);
        }
        if !self.state.is_running() {
            return None;
        }
        self.acquire(now)
    }
}
