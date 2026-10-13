//! The capture and encoder a Windows host runs, built as a pair. The encoder reads the frames the capture acquires, on the
//! capture's own D3D11 device, through one shared link.

mod capture;
mod encoder;

use std::sync::{Arc, Mutex, PoisonError};

use peering_core::ports::capture::Capture;
use peering_core::ports::encoder::Encoder;
use windows::Win32::Graphics::Direct3D11::ID3D11Texture2D;

use crate::gpu::GpuContext;
use crate::link::{BoundDevice, FrameLink};

use capture::LinkedCapture;
use encoder::PlatformEncoder;

/// The link between capture and encoder, shared by both. COM pointers are not `Send` in windows-core, so the pair is moved to the
/// runtime's thread as a whole before use and the D3D11 objects are touched only from that thread afterwards.
#[derive(Clone)]
pub(super) struct SharedLink(Arc<Mutex<FrameLink<GpuContext, ID3D11Texture2D>>>);

// SAFETY: see `SharedLink`; the link is never used from two threads at once.
unsafe impl Send for SharedLink {}

/// The capture and encoder for this machine. Both are boxed so the host can own them as its adapters.
pub struct PlatformServices {
    pub capture: Box<dyn Capture + Send>,
    pub encoder: Box<dyn Encoder + Send>,
}

impl PlatformServices {
    pub fn new() -> Self {
        let link = SharedLink(Arc::new(Mutex::new(FrameLink::default())));
        Self {
            capture: Box::new(LinkedCapture::new(link.clone())),
            encoder: Box::new(PlatformEncoder::new(link)),
        }
    }
}

impl Default for PlatformServices {
    fn default() -> Self {
        Self::new()
    }
}

fn locked(link: &SharedLink) -> std::sync::MutexGuard<'_, FrameLink<GpuContext, ID3D11Texture2D>> {
    link.0.lock().unwrap_or_else(PoisonError::into_inner)
}

fn bound_device(gpu: Option<GpuContext>) -> Option<BoundDevice<GpuContext>> {
    gpu.map(|gpu| BoundDevice { key: gpu.key(), device: gpu })
}
