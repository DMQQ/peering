//! `Encoder` port for Media Foundation. It owns the D3D11 device manager, one open MFT session, the NV12 converter and
//! the frame pipeline. Captured textures enter through `accept_capture`, which converts them at once; `encode` takes the
//! staged NV12 frame and turns it into the outputs the wire needs.

use super::sys::{self, Session};
use super::{frame_duration, frame_time, h264_config, video_timestamp, ConfigTracker, EncoderSettings};
use crate::convert::Nv12Converter;
use crate::gpu::GpuContext;
use crate::handoff::{FrameHandoff, Pipeline};
use peering_core::ports::capture::RawFrame;
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_wire::annexb::annexb_to_avcc;
use peering_wire::video::EncodedVideoFrame;
use windows::core::{Error as WinError, Result as WinResult};
use windows::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11Texture2D};
use windows::Win32::Media::MediaFoundation::IMFDXGIDeviceManager;

pub struct MftEncoder {
    source_id: String,
    manager: IMFDXGIDeviceManager,
    session: Option<Session>,
    converter: Nv12Converter,
    pipeline: Pipeline<ID3D11Texture2D>,
    config: ConfigTracker,
}

impl MftEncoder {
    /// `device` must be the device that created the textures passed to `accept_capture`.
    pub fn new(source_id: String, device: &ID3D11Device) -> WinResult<Self> {
        sys::startup()?;
        let manager = match sys::device_manager(device) {
            Ok(manager) => manager,
            Err(error) => {
                sys::shutdown();
                return Err(error);
            }
        };
        Ok(Self {
            source_id,
            manager,
            session: None,
            converter: Nv12Converter::new(),
            pipeline: Pipeline::default(),
            config: ConfigTracker::default(),
        })
    }

    /// Converts a captured texture to NV12 at the session size and stages it for the next `encode`. `gpu` must be the device
    /// this encoder was created on. Call it before the capture is polled again, because the texture is released by that poll.
    pub fn accept_capture(&mut self, captured: FrameHandoff<ID3D11Texture2D>, gpu: &GpuContext) -> Result<(), EncodeError> {
        let session = self.session.as_ref().ok_or(EncodeError::NotConfigured)?;
        let size = (session.settings.width, session.settings.height);
        let converter = &mut self.converter;
        self.pipeline.accept_capture(captured, |input| {
            converter.convert(&input, size, gpu).map_err(|error| failed("converting the capture to NV12", error))
        })
    }
}

impl Drop for MftEncoder {
    fn drop(&mut self) {
        self.session = None;
        sys::shutdown();
    }
}

impl Encoder for MftEncoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        let settings = EncoderSettings::new(width, height, fps, bitrate_bps)?;
        self.session = None;
        self.pipeline = Pipeline::default();
        let session = sys::open(&self.manager, settings).map_err(|error| failed("opening the H.264 encoder", error))?;
        self.session = Some(session.ok_or_else(|| {
            EncodeError::Unsupported("no D3D11 aware H.264 encoder accepted the settings".to_owned())
        })?);
        Ok(())
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        let session = self.session.as_ref().ok_or(EncodeError::NotConfigured)?;
        if force_keyframe {
            self.pipeline.request_keyframe();
        }
        let request = self
            .pipeline
            .take_encode()
            .ok_or_else(|| EncodeError::Failed(format!("no converted frame staged for sequence {}", frame.sequence)))?;
        let settings = session.settings;
        let sample = sys::io::wrap_texture(&request.frame.texture)
            .map_err(|error| failed("wrapping the converted frame", error))?;
        sys::io::set_timing(&sample, frame_time(request.frame.sequence, settings.fps), frame_duration(settings.fps))
            .map_err(|error| failed("timing the frame", error))?;
        if request.force_keyframe {
            sys::force_keyframe(session).map_err(|error| failed("requesting a keyframe", error))?;
        }
        let encoded = sys::io::submit_and_drain(session, &sample).map_err(|error| failed("encoding the frame", error))?;
        Ok(encoded
            .into_iter()
            .filter_map(|bytes| to_output(&mut self.config, &self.source_id, settings, bytes))
            .collect())
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        let Some(session) = self.session.as_mut() else {
            return;
        };
        session.settings.bitrate_bps = bitrate_bps;
        // A failed write leaves the previous rate in force, and the trait has no error channel to report it.
        let _written = sys::set_bitrate(session, bitrate_bps);
    }
}

/// Splits one Annex-B output into the stream description (when it changed) and an AVCC frame. Parameter sets stay out of
/// the frame; an output with no picture data yields nothing.
fn to_output(
    config: &mut ConfigTracker,
    source_id: &str,
    settings: EncoderSettings,
    bytes: sys::io::EncodedBytes,
) -> Option<EncodedOutput> {
    let converted = annexb_to_avcc(&bytes.annexb);
    if converted.avcc.is_empty() {
        return None;
    }
    let candidate = h264_config(source_id, settings.width, settings.height, converted.sps, converted.pps);
    Some(EncodedOutput {
        config: config.observe(candidate),
        frame: EncodedVideoFrame {
            is_keyframe: converted.is_keyframe,
            pixel_width: settings.width,
            pixel_height: settings.height,
            presentation_time: video_timestamp(bytes.hundred_nanoseconds),
            data: converted.avcc,
        },
    })
}

fn failed(context: &str, error: WinError) -> EncodeError {
    EncodeError::Failed(format!("{context}: {error}"))
}
