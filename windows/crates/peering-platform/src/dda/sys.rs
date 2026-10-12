//! The DXGI duplication loop behind `Capture`. Frame textures stay on the GPU until the encoder takes them.

mod open;

use std::time::Instant;

use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};
use windows::core::{Interface, HRESULT};
use windows::Win32::Graphics::Direct3D11::{ID3D11Texture2D, D3D11_TEXTURE2D_DESC};
use windows::Win32::Graphics::Dxgi::{
    IDXGIResource, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
};

use crate::dda::{classify, CaptureState, Classification, HresultKind};
use crate::monitors;
use open::{open_session, Session};

const ACQUIRE_TIMEOUT_MS: u32 = 2;

pub struct DesktopDuplicationCapture {
    started: Instant,
    state: CaptureState,
    target_device_name: Option<String>,
    session: Option<Session>,
    frame_held: bool,
    texture: Option<ID3D11Texture2D>,
    sequence: u64,
}

impl DesktopDuplicationCapture {
    pub fn new() -> Self {
        Self {
            started: Instant::now(),
            state: CaptureState::Idle,
            target_device_name: None,
            session: None,
            frame_held: false,
            texture: None,
            sequence: 0,
        }
    }

    /// The texture of the frame `poll_frame` last returned. It is valid until the next `poll_frame`, which releases
    /// the desktop frame it came from.
    pub fn take_texture(&mut self) -> Option<ID3D11Texture2D> {
        self.texture.take()
    }

    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    fn release_frame(&mut self) {
        self.texture = None;
        if std::mem::take(&mut self.frame_held) {
            if let Some(session) = &self.session {
                // SAFETY: `frame_held` means a frame was acquired on this duplication and not yet released.
                let _ = unsafe { session.duplication.ReleaseFrame() };
            }
        }
    }

    fn reacquire(&mut self, now: f64) {
        let Some(device_name) = self.target_device_name.clone() else {
            return;
        };
        match open_session(&device_name) {
            Ok(session) => {
                self.session = Some(session);
                self.state.reacquired();
            }
            Err(_) => self.state.reacquire_failed(now),
        }
    }

    fn acquire(&mut self, now: f64) -> Option<RawFrame> {
        let session = self.session.as_ref()?;
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource: Option<IDXGIResource> = None;
        // SAFETY: both out pointers are live locals; `poll_frame` releases any earlier frame before calling this.
        let result = unsafe { session.duplication.AcquireNextFrame(ACQUIRE_TIMEOUT_MS, &mut info, &mut resource) };
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
        self.texture = Some(texture);
        Some(frame)
    }

    fn on_acquire_error(&mut self, kind: HresultKind, now: f64) {
        match classify(kind) {
            Classification::NewFrame | Classification::NoNewFrame => {}
            Classification::AccessLost => {
                self.session = None;
                self.state.access_lost(now);
            }
            Classification::Fatal => {
                self.session = None;
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
        match open_session(&device_name) {
            Ok(session) => {
                self.session = Some(session);
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
        self.session = None;
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
