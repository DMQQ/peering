//! The host's video lane: sealed datagrams on the relay path, and the control connection when video falls back to it.

use peering_wire::chunks::{self, CONTROL_CHUNK_SIZE};
use peering_wire::fallback::{HostAnswer, HostFallbackGate, CONTROL_LANE_CAP_KBPS, PRIMARY_PROBE_INTERVAL};
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::{VideoKeyGrant, VideoTransportKind, VideoTransportRequest};
use peering_wire::sealing::{Direction, Opener, SealError, Sealer, SECRET_SIZE, TOKEN_SIZE};
use peering_wire::video::VideoWireError;
use thiserror::Error;

use super::coordinator::VideoOutput;

/// Only the lane's key material comes from here, so the caller decides where randomness is taken from.
pub trait Random {
    /// False when no secure bytes could be drawn; the buffer then holds nothing usable.
    fn fill(&mut self, buffer: &mut [u8]) -> bool;
}

/// The lane sends a keepalive bind this often, so the relay keeps this end's mapping open.
pub const BIND_KEEPALIVE_INTERVAL: f64 = 5.0;

#[derive(Debug, Error)]
pub enum LaneError {
    #[error(transparent)]
    Seal(#[from] SealError),
    #[error(transparent)]
    Wire(#[from] VideoWireError),
    #[error("a payload of {0} bytes cannot be split into pieces")]
    TooLarge(usize),
    #[error("a video message could not be encoded as JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("no secure random bytes were available for the video key")]
    RandomUnavailable,
}

/// What to write to one lane. Datagrams go to the relay; frames go on the control connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaneSend {
    Datagram(Vec<u8>),
    ControlFrames(Vec<Frame>),
}

struct DatagramKeys {
    sealer: Sealer,
    probe_opener: Opener,
}

pub struct VideoLane {
    video_token: [u8; TOKEN_SIZE],
    datagrams: Option<DatagramKeys>,
    transport: VideoTransportKind,
    last_frame_at: Option<f64>,
    last_probe_at: Option<f64>,
    last_bind_at: Option<f64>,
    control_frame_id: u32,
}

impl VideoLane {
    /// `video_token` is this session's token from the relay, the same one every sealed datagram is prefixed with.
    pub fn new(video_token: [u8; TOKEN_SIZE]) -> Self {
        Self {
            video_token,
            datagrams: None,
            transport: VideoTransportKind::Primary,
            last_frame_at: None,
            last_probe_at: None,
            last_bind_at: None,
            control_frame_id: 0,
        }
    }

    /// Draws a fresh secret, keys the lane with it, and returns the `videoKey` frame that carries it to the client.
    /// A second request replaces the first key, so only the newest grant can open what is sent from now on.
    pub fn answer_key_request(&mut self, random: &mut dyn Random) -> Result<Frame, LaneError> {
        let mut secret = [0u8; SECRET_SIZE];
        if !random.fill(&mut secret) {
            return Err(LaneError::RandomUnavailable);
        }
        self.datagrams = Some(DatagramKeys {
            sealer: Sealer::new(&secret, Direction::HostToClient, self.video_token)?,
            probe_opener: Opener::new(&secret, Direction::ClientToHost)?,
        });
        let grant = VideoKeyGrant { secret: secret.to_vec() };
        Ok(Frame::new(MessageKind::VideoKey, serde_json::to_vec(&grant)?))
    }

    /// Answers a client's request to move video. Moving to the control lane is declined while nothing has been
    /// produced recently, because a still screen and a blocked path look the same from here.
    pub fn handle_transport_request(&mut self, request: &VideoTransportRequest, now: f64) -> HostAnswer {
        match request.transport {
            VideoTransportKind::Primary => {
                self.transport = VideoTransportKind::Primary;
                HostAnswer::Serve
            }
            VideoTransportKind::Control => match HostFallbackGate.decide(now, self.last_frame_at) {
                HostAnswer::Serve => {
                    self.transport = VideoTransportKind::Control;
                    HostAnswer::Serve
                }
                HostAnswer::Decline => HostAnswer::Decline,
            },
        }
    }

    pub fn transport(&self) -> VideoTransportKind {
        self.transport
    }

    /// The bitrate ceiling the encoder must respect on the current lane, for the caller to hand to the coordinator.
    pub fn bitrate_ceiling_kbps(&self) -> Option<u32> {
        match self.transport {
            VideoTransportKind::Control => Some(CONTROL_LANE_CAP_KBPS),
            VideoTransportKind::Primary => None,
        }
    }

    /// The bind datagram that registers this end's address with the relay: the token alone, forwarded nowhere.
    /// Returns it on the first call and again once the keepalive interval has passed.
    pub fn bind_if_due(&mut self, now: f64) -> Option<Vec<u8>> {
        let due = self.last_bind_at.is_none_or(|sent| now - sent >= BIND_KEEPALIVE_INTERVAL);
        if !due {
            return None;
        }
        self.last_bind_at = Some(now);
        Some(self.video_token.to_vec())
    }

    /// Seals one message on the host's send key, for replies and probes. Empty until a key has been granted. The
    /// datagrams carry the token in front, as `send` produces them.
    pub fn seal_datagrams(&mut self, kind: MessageKind, payload: &[u8]) -> Vec<Vec<u8>> {
        match self.datagrams.as_mut() {
            Some(keys) => keys.sealer.seal(kind, payload),
            None => Vec::new(),
        }
    }

    /// Opens a datagram the client sent on this lane, as the relay forwarded it (token already removed).
    /// `Ok(None)` is a replay or a piece of a picture still waiting for its other pieces.
    pub fn open_from_client(&mut self, forwarded: &[u8]) -> Result<Option<Frame>, LaneError> {
        match self.datagrams.as_mut() {
            Some(keys) => Ok(keys.probe_opener.open(forwarded)?),
            None => Ok(None),
        }
    }

    /// What to write for one output, in the order it must go out. On the control lane, a keyframe or a description
    /// is also sent on the primary lane when a key exists, so the client can see the primary lane recover.
    pub fn send(&mut self, output: &VideoOutput, now: f64) -> Result<Vec<LaneSend>, LaneError> {
        let (kind, payload, is_keyframe) = match output {
            VideoOutput::Config(config) => (MessageKind::VideoConfig, serde_json::to_vec(config)?, false),
            VideoOutput::Frame(frame) => {
                self.last_frame_at = Some(now);
                (MessageKind::VideoFrame, frame.encode()?, frame.is_keyframe)
            }
        };
        let mut sends = Vec::new();
        if self.transport == VideoTransportKind::Control && self.probe_due(output, now) {
            if let Some(keys) = self.datagrams.as_mut() {
                sends.extend(seal_all(keys, kind, &payload)?);
            }
            if is_keyframe {
                self.last_probe_at = Some(now);
            }
        }
        sends.extend(self.carry(kind, payload)?);
        Ok(sends)
    }

    fn probe_due(&self, output: &VideoOutput, now: f64) -> bool {
        match output {
            VideoOutput::Config(_) => true,
            VideoOutput::Frame(frame) => {
                frame.is_keyframe && self.last_probe_at.is_none_or(|probed| now - probed >= PRIMARY_PROBE_INTERVAL)
            }
        }
    }

    fn carry(&mut self, kind: MessageKind, payload: Vec<u8>) -> Result<Vec<LaneSend>, LaneError> {
        match (self.transport, self.datagrams.as_mut()) {
            (VideoTransportKind::Primary, Some(keys)) => Ok(seal_all(keys, kind, &payload)?),
            (VideoTransportKind::Primary, None) => Ok(vec![LaneSend::ControlFrames(vec![Frame::new(kind, payload)])]),
            (VideoTransportKind::Control, _) => {
                self.control_frame_id = self.control_frame_id.wrapping_add(1);
                let pieces = chunks::encode(kind, &payload, self.control_frame_id, CONTROL_CHUNK_SIZE);
                if pieces.is_empty() {
                    return Err(LaneError::TooLarge(payload.len()));
                }
                Ok(vec![LaneSend::ControlFrames(pieces)])
            }
        }
    }
}

fn seal_all(keys: &mut DatagramKeys, kind: MessageKind, payload: &[u8]) -> Result<Vec<LaneSend>, LaneError> {
    let datagrams = keys.sealer.seal(kind, payload);
    if datagrams.is_empty() {
        return Err(LaneError::TooLarge(payload.len()));
    }
    Ok(datagrams.into_iter().map(LaneSend::Datagram).collect())
}

#[cfg(test)]
mod tests;
