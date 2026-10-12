//! `Encoder` port for Media Foundation. It owns the D3D11 device manager and one open MFT session, and turns each staged
//! texture into the outputs the wire needs.

use super::sys::{self, Session};
use super::{frame_duration, frame_time, h264_config, video_timestamp, ConfigTracker, EncoderSettings};
use peering_core::ports::capture::RawFrame;
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_wire::annexb::annexb_to_avcc;
use peering_wire::video::EncodedVideoFrame;
use windows::core::{Error as WinError, Result as WinResult};
use windows::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11Texture2D};
use windows::Win32::Media::MediaFoundation::{IMFDXGIDeviceManager, IMFSample};

pub struct MftEncoder {
    source_id: String,
    manager: IMFDXGIDeviceManager,
    session: Option<Session>,
    staged: Option<IMFSample>,
    config: ConfigTracker,
}

impl MftEncoder {
    /// `device` must be the device that created the textures passed to `stage_texture`.
    pub fn new(source_id: String, device: &ID3D11Device) -> WinResult<Self> {
        sys::startup()?;
        let manager = match sys::device_manager(device) {
            Ok(manager) => manager,
            Err(error) => {
                sys::shutdown();
                return Err(error);
            }
        };
        Ok(Self { source_id, manager, session: None, staged: None, config: ConfigTracker::default() })
    }

    /// The input for the next `encode`: an NV12 texture on the device this encoder was created with.
    pub fn stage_texture(&mut self, texture: &ID3D11Texture2D) -> Result<(), EncodeError> {
        let sample = sys::io::wrap_texture(texture).map_err(|error| failed("wrapping the capture texture", error))?;
        self.staged = Some(sample);
        Ok(())
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
        self.staged = None;
        let session = sys::open(&self.manager, settings).map_err(|error| failed("opening the H.264 encoder", error))?;
        self.session = Some(session.ok_or_else(|| {
            EncodeError::Unsupported("no D3D11 aware H.264 encoder accepted the settings".to_owned())
        })?);
        Ok(())
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        let session = self.session.as_ref().ok_or(EncodeError::NotConfigured)?;
        let sample = self
            .staged
            .take()
            .ok_or_else(|| EncodeError::Failed(format!("no texture staged for frame {}", frame.sequence)))?;
        let settings = session.settings;
        sys::io::set_timing(&sample, frame_time(frame.sequence, settings.fps), frame_duration(settings.fps))
            .map_err(|error| failed("timing the frame", error))?;
        if force_keyframe {
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
