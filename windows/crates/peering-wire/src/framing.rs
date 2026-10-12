//! Length prefixed frames: `u32 length (kind + payload)`, `u8 kind`, payload. See docs/protocol.md section 3.

use thiserror::Error;

pub const MAX_FRAME_LENGTH: u32 = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MessageKind {
    ConnectionRole = 0x01,
    ClientHello = 0x02,
    ServerHello = 0x03,
    PairConfirm = 0x04,
    PairResult = 0x05,
    Command = 0x06,
    Catalog = 0x07,
    SetCaptureSource = 0x08,
    VideoConfig = 0x09,
    VideoFrame = 0x0A,
    Ping = 0x0B,
    Pong = 0x0C,
    Error = 0x0D,
    PairCommit = 0x0E,
    PairReveal = 0x0F,
    Notice = 0x10,
    ClipboardContent = 0x11,
    AudioConfig = 0x13,
    AudioFrame = 0x14,
    TerminalRequest = 0x15,
    TerminalEvent = 0x16,
    VideoChunk = 0x17,
    VideoTransport = 0x18,
    VideoKeyRequest = 0x19,
    VideoKey = 0x1A,
    DirectProbe = 0x1B,
    TextFocus = 0x1C,
    FieldState = 0x1D,
    AgentRequest = 0x1E,
    AgentEvent = 0x1F,
    PreviewRequest = 0x20,
    PreviewEvent = 0x21,
    PointerReport = 0x22,
    ClientState = 0x23,
}

impl MessageKind {
    pub fn from_byte(byte: u8) -> Option<Self> {
        use MessageKind::*;
        Some(match byte {
            0x01 => ConnectionRole,
            0x02 => ClientHello,
            0x03 => ServerHello,
            0x04 => PairConfirm,
            0x05 => PairResult,
            0x06 => Command,
            0x07 => Catalog,
            0x08 => SetCaptureSource,
            0x09 => VideoConfig,
            0x0A => VideoFrame,
            0x0B => Ping,
            0x0C => Pong,
            0x0D => Error,
            0x0E => PairCommit,
            0x0F => PairReveal,
            0x10 => Notice,
            0x11 => ClipboardContent,
            0x13 => AudioConfig,
            0x14 => AudioFrame,
            0x15 => TerminalRequest,
            0x16 => TerminalEvent,
            0x17 => VideoChunk,
            0x18 => VideoTransport,
            0x19 => VideoKeyRequest,
            0x1A => VideoKey,
            0x1B => DirectProbe,
            0x1C => TextFocus,
            0x1D => FieldState,
            0x1E => AgentRequest,
            0x1F => AgentEvent,
            0x20 => PreviewRequest,
            0x21 => PreviewEvent,
            0x22 => PointerReport,
            0x23 => ClientState,
            _ => return None,
        })
    }
}

/// Which stream a connection carries; the payload of the first frame on every connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionRole {
    Control = 1,
    Video = 2,
}

impl ConnectionRole {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Control),
            2 => Some(Self::Video),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: MessageKind,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: MessageKind, payload: Vec<u8>) -> Self {
        Self { kind, payload }
    }

    pub fn empty(kind: MessageKind) -> Self {
        Self::new(kind, Vec::new())
    }

    pub fn encode(&self) -> Vec<u8> {
        encode(self.kind, &self.payload)
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum FramingError {
    #[error("frame of {declared} bytes exceeds the limit")]
    FrameTooLarge { declared: u32 },
    #[error("frame with zero length")]
    ZeroLength,
    #[error("unknown message kind {0:#04x}")]
    UnknownKind(u8),
}

pub fn encode(kind: MessageKind, payload: &[u8]) -> Vec<u8> {
    let length = payload.len() as u32 + 1;
    let mut out = Vec::with_capacity(5 + payload.len());
    out.extend_from_slice(&length.to_be_bytes());
    out.push(kind as u8);
    out.extend_from_slice(payload);
    out
}

/// Accumulates bytes from any read size and yields whole frames. The declared length is checked before the payload is buffered.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
    read: usize,
}

impl FrameDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn buffered(&self) -> usize {
        self.buffer.len() - self.read
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    pub fn next_frame(&mut self) -> Result<Option<Frame>, FramingError> {
        let available = &self.buffer[self.read..];
        if available.len() < 4 {
            self.compact();
            return Ok(None);
        }
        let length = u32::from_be_bytes([available[0], available[1], available[2], available[3]]);
        if length == 0 {
            return Err(FramingError::ZeroLength);
        }
        if length > MAX_FRAME_LENGTH {
            return Err(FramingError::FrameTooLarge { declared: length });
        }
        let total = 4 + length as usize;
        if available.len() < total {
            self.compact();
            return Ok(None);
        }
        let raw_kind = available[4];
        let kind = MessageKind::from_byte(raw_kind).ok_or(FramingError::UnknownKind(raw_kind))?;
        let payload = available[5..total].to_vec();
        self.read += total;
        self.compact();
        Ok(Some(Frame { kind, payload }))
    }

    fn compact(&mut self) {
        if self.read == self.buffer.len() {
            self.buffer.clear();
            self.read = 0;
        } else if self.read >= 64 * 1024 && self.read * 2 >= self.buffer.len() {
            self.buffer.drain(..self.read);
            self.read = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;

    fn bytes(hex_text: &str) -> Vec<u8> {
        hex::decode(hex_text).unwrap()
    }

    #[test]
    fn encodes_the_vector_frames() {
        for case in load("wire.json")["frames"].as_array().unwrap() {
            let kind = MessageKind::from_byte(case["kind"].as_u64().unwrap() as u8).unwrap();
            let payload = bytes(case["payload"].as_str().unwrap());
            assert_eq!(hex::encode(encode(kind, &payload)), case["bytes"].as_str().unwrap());
        }
    }

    #[test]
    fn delivers_frames_split_and_coalesced_across_reads() {
        let vector = &load("wire.json")["decoderSplit"];
        let mut decoder = FrameDecoder::new();
        let feeds = vector["feeds"].as_array().unwrap();
        let expected = vector["framesAfterEachFeed"].as_array().unwrap();
        for (feed, want) in feeds.iter().zip(expected) {
            decoder.push(&bytes(feed.as_str().unwrap()));
            let mut got = Vec::new();
            while let Some(frame) = decoder.next_frame().unwrap() {
                got.push((frame.kind as u8, hex::encode(frame.payload)));
            }
            let want: Vec<(u8, String)> = want
                .as_array()
                .unwrap()
                .iter()
                .map(|f| (f["kind"].as_u64().unwrap() as u8, f["payload"].as_str().unwrap().to_string()))
                .collect();
            assert_eq!(got, want);
        }
    }

    #[test]
    fn rejects_the_vector_errors_before_buffering_a_payload() {
        for case in load("wire.json")["decoderErrors"].as_array().unwrap() {
            let mut decoder = FrameDecoder::new();
            decoder.push(&bytes(case["bytes"].as_str().unwrap()));
            let error = decoder.next_frame().unwrap_err();
            let name = match error {
                FramingError::ZeroLength => "zeroLength",
                FramingError::FrameTooLarge { .. } => "tooLarge",
                FramingError::UnknownKind(_) => "unknownKind",
            };
            assert_eq!(name, case["error"].as_str().unwrap(), "{}", case["name"]);
        }
    }

    #[test]
    fn waits_for_the_rest_of_a_partial_frame() {
        let mut decoder = FrameDecoder::new();
        let whole = encode(MessageKind::Ping, b"{}");
        decoder.push(&whole[..whole.len() - 1]);
        assert_eq!(decoder.next_frame().unwrap(), None);
        decoder.push(&whole[whole.len() - 1..]);
        assert_eq!(decoder.next_frame().unwrap().unwrap().payload, b"{}");
        assert_eq!(decoder.buffered(), 0);
    }

    #[test]
    fn every_kind_round_trips_through_its_byte() {
        for byte in 0..=255u8 {
            if let Some(kind) = MessageKind::from_byte(byte) {
                assert_eq!(kind as u8, byte);
            }
        }
    }
}
