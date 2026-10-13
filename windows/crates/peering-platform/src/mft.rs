//! H.264 encoder through Media Foundation, the `Encoder` port on Windows. Hardware MFTs are tried before the Microsoft
//! software encoder. Captured textures enter through `MftEncoder::accept_capture`, which converts them to NV12 and stages
//! them in the `handoff` pipeline; output is Annex-B from the MFT, converted to AVCC for the wire. The pure parts (settings, candidate order, timing, config
//! changes) are tested on any OS; the Media Foundation calls live in `mft/sys.rs` and `mft/encoder.rs`.
//!
//! Compile-checked only, not run on Windows. Unverified: asynchronous hardware MFTs are not event driven yet (no
//! METransformNeedInput or HaveOutput gating; only the MF_E_NOTACCEPTING drain-and-retry is in place); which
//! CODECAPI_* properties each vendor accepts (the rate control, low latency and bitrate ones are required, GOP and
//! B-picture count are best effort); the stream change renegotiation; the sample timing a hardware MFT expects; and the
//! D3D11 device manager handoff on each vendor.

mod candidates;
mod config;
mod settings;
mod timing;

#[cfg(windows)]
mod encoder;
#[cfg(windows)]
mod sys;

#[cfg(test)]
mod tests;

pub use candidates::{rank_candidates, CandidateInfo};
pub use config::{h264_config, ConfigTracker};
pub use settings::EncoderSettings;
pub use timing::{frame_duration, frame_time, video_timestamp, HUNDRED_NANOSECONDS_PER_SECOND};

#[cfg(windows)]
pub use encoder::MftEncoder;
