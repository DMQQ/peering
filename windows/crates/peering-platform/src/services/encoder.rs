//! The H.264 `Encoder` port over Media Foundation, bound to the capture's device. The encoder is reopened when the device
//! changes adapter, and when a captured frame no longer matches the size it runs at (a display mode change).

use peering_core::ports::capture::RawFrame;
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_wire::quality::even_size;

use super::{locked, SharedLink};
use crate::gpu::GpuContext;
use crate::link::{binding_for, resize_for, AdapterKey, Binding};
use crate::mft::MftEncoder;

struct Bound {
    adapter: AdapterKey,
    encoder: MftEncoder,
}

#[derive(Clone, Copy)]
struct Running {
    width: u32,
    height: u32,
    fps: u32,
    bitrate_bps: u32,
}

pub struct PlatformEncoder {
    link: SharedLink,
    bound: Option<Bound>,
    running: Option<Running>,
}

// SAFETY: the encoder owns Media Foundation and D3D11 objects that are used from one thread only, the one the host moves it to
// before use; see `SharedLink`.
unsafe impl Send for PlatformEncoder {}

impl PlatformEncoder {
    pub fn new(link: SharedLink) -> Self {
        Self { link, bound: None, running: None }
    }

    fn current_gpu(&self) -> Result<(AdapterKey, GpuContext), EncodeError> {
        let link = locked(&self.link);
        let bound = link.device().ok_or(EncodeError::NotConfigured)?;
        Ok((bound.adapter, bound.device.clone()))
    }

    fn bind_to(&mut self, adapter: AdapterKey, gpu: &GpuContext) -> Result<(), EncodeError> {
        if binding_for(self.bound.as_ref().map(|bound| bound.adapter), adapter) == Binding::Reuse {
            return Ok(());
        }
        self.bound = None;
        let encoder = MftEncoder::new(String::new(), &gpu.device)
            .map_err(|error| EncodeError::Failed(format!("binding the encoder to the capture device: {error}")))?;
        self.bound = Some(Bound { adapter, encoder });
        Ok(())
    }

    fn reopen_at(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        let (adapter, gpu) = self.current_gpu()?;
        self.bind_to(adapter, &gpu)?;
        let bound = self.bound.as_mut().ok_or(EncodeError::NotConfigured)?;
        bound.encoder.configure(width, height, fps, bitrate_bps)?;
        self.running = Some(Running { width, height, fps, bitrate_bps });
        Ok(())
    }
}

impl Encoder for PlatformEncoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        let (width, height) = even_size(width, height);
        self.reopen_at(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        let running = self.running.ok_or(EncodeError::NotConfigured)?;
        let (adapter, gpu) = self.current_gpu()?;
        let captured = locked(&self.link)
            .take_frame()
            .ok_or_else(|| EncodeError::Failed(format!("no captured texture for frame {}", frame.sequence)))?;
        let mut force_keyframe = force_keyframe;
        if let Some((width, height)) = resize_for(Some((running.width, running.height)), (frame.width, frame.height)) {
            self.reopen_at(width, height, running.fps, running.bitrate_bps)?;
            force_keyframe = true;
        }
        self.bind_to(adapter, &gpu)?;
        let bound = self.bound.as_mut().ok_or(EncodeError::NotConfigured)?;
        bound.encoder.accept_capture(captured, &gpu)?;
        bound.encoder.encode(frame, force_keyframe)
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        if let Some(running) = self.running.as_mut() {
            running.bitrate_bps = bitrate_bps;
        }
        if let Some(bound) = self.bound.as_mut() {
            bound.encoder.set_bitrate(bitrate_bps);
        }
    }
}
