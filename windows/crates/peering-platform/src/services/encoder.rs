//! The H.264 `Encoder` port over Media Foundation, bound to the capture's device. The encoder is reopened when the device
//! changes adapter, and when a captured frame no longer matches the size it runs at (a display mode change).

use peering_core::ports::capture::RawFrame;
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_wire::quality::even_size;
use windows::Win32::Graphics::Direct3D11::ID3D11Texture2D;

use super::{locked, SharedLink};
use crate::gpu::GpuContext;
use crate::handoff::FrameHandoff;
use crate::link::{binding_for, resize_for, Binding, DeviceKey};
use crate::mft::MftEncoder;

struct Bound {
    key: DeviceKey,
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
    /// The last captured frame, which a keyframe is made from when the screen has not changed since.
    last_captured: Option<FrameHandoff<ID3D11Texture2D>>,
}

// SAFETY: the encoder owns Media Foundation and D3D11 objects that are used from one thread only, the one the host moves it to
// before use; see `SharedLink`.
unsafe impl Send for PlatformEncoder {}

impl PlatformEncoder {
    pub fn new(link: SharedLink) -> Self {
        Self { link, bound: None, running: None, last_captured: None }
    }

    fn current_gpu(&self) -> Result<(DeviceKey, GpuContext), EncodeError> {
        let link = locked(&self.link);
        let bound = link.device().ok_or(EncodeError::NotConfigured)?;
        Ok((bound.key, bound.device.clone()))
    }

    fn bind_to(&mut self, key: DeviceKey, gpu: &GpuContext) -> Result<(), EncodeError> {
        if binding_for(self.bound.as_ref().map(|bound| bound.key), key) == Binding::Reuse {
            return Ok(());
        }
        self.bound = None;
        let encoder = MftEncoder::new(String::new(), &gpu.device)
            .map_err(|error| EncodeError::Failed(format!("binding the encoder to the capture device: {error}")))?;
        self.bound = Some(Bound { key, encoder });
        Ok(())
    }

    fn reopen_at(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        let (key, gpu) = self.current_gpu()?;
        self.bind_to(key, &gpu)?;
        self.last_captured = None;
        let bound = self.bound.as_mut().ok_or(EncodeError::NotConfigured)?;
        bound.encoder.configure(width, height, fps, bitrate_bps)?;
        self.running = Some(Running { width, height, fps, bitrate_bps });
        Ok(())
    }
}

impl PlatformEncoder {
    fn encode_frame(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        let running = self.running.ok_or(EncodeError::NotConfigured)?;
        let (key, gpu) = self.current_gpu()?;
        let fresh = locked(&self.link).take_frame();
        let captured = match fresh {
            Some(captured) => {
                self.last_captured = Some(duplicate(&captured));
                captured
            }
            None => self
                .last_captured
                .as_ref()
                .map(duplicate)
                .ok_or_else(|| EncodeError::Failed(format!("no captured texture for frame {}", frame.sequence)))?,
        };
        let mut force_keyframe = force_keyframe;
        let rebind = binding_for(self.bound.as_ref().map(|bound| bound.key), key) == Binding::Rebind;
        let resize = resize_for(Some((running.width, running.height)), (frame.width, frame.height));
        if let Some((width, height)) = resize.or(rebind.then_some((running.width, running.height))) {
            self.reopen_at(width, height, running.fps, running.bitrate_bps)?;
            force_keyframe = true;
        }
        let bound = self.bound.as_mut().ok_or(EncodeError::NotConfigured)?;
        bound.encoder.accept_capture(captured, &gpu)?;
        bound.encoder.encode(frame, force_keyframe)
    }
}

impl Encoder for PlatformEncoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        let (width, height) = even_size(width, height);
        self.reopen_at(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        let encoded = self.encode_frame(frame, force_keyframe);
        if encoded.is_err() {
            // A session that failed once is not trusted again: the coordinator's next `configure` opens a new one.
            self.bound = None;
        }
        encoded
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

/// Another handle to the same texture: the encoder only reads it, so a repeat of the frame needs no copy.
fn duplicate(captured: &FrameHandoff<ID3D11Texture2D>) -> FrameHandoff<ID3D11Texture2D> {
    FrameHandoff { sequence: captured.sequence, width: captured.width, height: captured.height, texture: captured.texture.clone() }
}
