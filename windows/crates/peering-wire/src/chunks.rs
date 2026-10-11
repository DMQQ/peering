//! Cutting a message into `videoChunk` frames and putting them back. See docs/protocol/video.md section 5.

use crate::framing::{Frame, MessageKind};
use std::collections::HashMap;
use thiserror::Error;

pub const HEADER_SIZE: usize = 9;
pub const CONTROL_CHUNK_SIZE: usize = 16 * 1024;
pub const DATAGRAM_CHUNK_SIZE: usize = 1024;
pub const MAX_REASSEMBLED: usize = 4 * 1024 * 1024;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ChunkError {
    #[error("chunk header truncated: have {have} bytes")]
    TruncatedHeader { have: usize },
    #[error("chunk index {index} out of range for count {count}")]
    OutOfRange { index: usize, count: usize },
    #[error("a chunk may not carry a chunk")]
    Nested,
    #[error("chunk body of {0} bytes is too large")]
    Oversized(usize),
}

/// A payload that fits one piece goes out as itself, not as a chunk. Returns nothing for a payload needing more than 65535 pieces.
pub fn encode(kind: MessageKind, payload: &[u8], frame_id: u32, chunk_size: usize) -> Vec<Frame> {
    let size = chunk_size.max(1);
    if payload.len() <= size {
        return vec![Frame::new(kind, payload.to_vec())];
    }
    let count = payload.len().div_ceil(size);
    if count > u16::MAX as usize {
        return Vec::new();
    }
    payload
        .chunks(size)
        .enumerate()
        .map(|(index, part)| {
            let mut body = Vec::with_capacity(HEADER_SIZE + part.len());
            body.push(kind as u8);
            body.extend_from_slice(&frame_id.to_be_bytes());
            body.extend_from_slice(&(index as u16).to_be_bytes());
            body.extend_from_slice(&(count as u16).to_be_bytes());
            body.extend_from_slice(part);
            Frame::new(MessageKind::VideoChunk, body)
        })
        .collect()
}

/// One per lane: two lanes number their chunks independently, so sharing one would read the other's chunks as a newer picture.
#[derive(Debug)]
pub struct Reassembler {
    max_reassembled: usize,
    frame_id: Option<u32>,
    inner_kind: Option<MessageKind>,
    expected: usize,
    parts: HashMap<usize, Vec<u8>>,
    bytes: usize,
}

impl Default for Reassembler {
    fn default() -> Self {
        Self::new(MAX_REASSEMBLED)
    }
}

impl Reassembler {
    pub fn new(max_reassembled: usize) -> Self {
        Self { max_reassembled, frame_id: None, inner_kind: None, expected: 0, parts: HashMap::new(), bytes: 0 }
    }

    pub fn ingest(&mut self, frame: &Frame) -> Result<Option<Frame>, ChunkError> {
        let payload = &frame.payload;
        if payload.len() < HEADER_SIZE {
            return Err(ChunkError::TruncatedHeader { have: payload.len() });
        }
        let inner = MessageKind::from_byte(payload[0]).filter(|k| *k != MessageKind::VideoChunk).ok_or(ChunkError::Nested)?;
        let frame_id = u32::from_be_bytes([payload[1], payload[2], payload[3], payload[4]]);
        let index = u16::from_be_bytes([payload[5], payload[6]]) as usize;
        let count = u16::from_be_bytes([payload[7], payload[8]]) as usize;
        if count == 0 || index >= count {
            return Err(ChunkError::OutOfRange { index, count });
        }
        let body = &payload[HEADER_SIZE..];
        if body.len() > CONTROL_CHUNK_SIZE {
            return Err(ChunkError::Oversized(body.len()));
        }

        if self.frame_id != Some(frame_id) {
            self.clear();
            self.frame_id = Some(frame_id);
            self.inner_kind = Some(inner);
            self.expected = count;
        }
        if Some(inner) != self.inner_kind || count != self.expected {
            return Ok(None);
        }
        if !self.parts.contains_key(&index) {
            self.bytes += body.len();
            self.parts.insert(index, body.to_vec());
        }
        if self.bytes > self.max_reassembled {
            self.clear();
            return Ok(None);
        }
        if self.parts.len() != self.expected {
            return Ok(None);
        }
        let mut assembled = Vec::with_capacity(self.bytes);
        for i in 0..self.expected {
            assembled.extend_from_slice(&self.parts[&i]);
        }
        let kind = inner;
        self.clear();
        Ok(Some(Frame::new(kind, assembled)))
    }

    fn clear(&mut self) {
        self.frame_id = None;
        self.inner_kind = None;
        self.expected = 0;
        self.parts.clear();
        self.bytes = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;

    fn payload() -> Vec<u8> {
        (0..2500).map(|i| (i % 251) as u8).collect()
    }

    fn pieces(vector: &serde_json::Value) -> Vec<Frame> {
        vector
            .as_array()
            .unwrap()
            .iter()
            .map(|p| {
                let bytes = hex::decode(p.as_str().unwrap()).unwrap();
                let mut decoder = crate::framing::FrameDecoder::new();
                decoder.push(&bytes);
                decoder.next_frame().unwrap().unwrap()
            })
            .collect()
    }

    #[test]
    fn encoding_matches_the_vector_pieces() {
        let v = load("wire.json");
        let want = pieces(&v["chunks"]["pieces"]);
        let got = encode(MessageKind::VideoFrame, &payload(), 7, 1024);
        assert_eq!(got, want);
    }

    #[test]
    fn small_payload_is_not_chunked() {
        let got = encode(MessageKind::Ping, b"abc", 1, 1024);
        assert_eq!(got, vec![Frame::new(MessageKind::Ping, b"abc".to_vec())]);
    }

    #[test]
    fn reassembles_in_order_and_reversed() {
        let all = pieces(&load("wire.json")["chunks"]["pieces"]);
        for order in [vec![0, 1, 2], vec![2, 1, 0], vec![1, 0, 2]] {
            let mut reassembler = Reassembler::default();
            let mut done = None;
            for i in order {
                done = reassembler.ingest(&all[i]).unwrap().or(done);
            }
            assert_eq!(done, Some(Frame::new(MessageKind::VideoFrame, payload())));
        }
    }

    #[test]
    fn a_lost_piece_means_no_picture() {
        let all = pieces(&load("wire.json")["chunks"]["pieces"]);
        let mut reassembler = Reassembler::default();
        assert_eq!(reassembler.ingest(&all[0]).unwrap(), None);
        assert_eq!(reassembler.ingest(&all[2]).unwrap(), None);
    }

    #[test]
    fn a_newer_frame_discards_the_one_in_progress() {
        let v = load("wire.json");
        let old = pieces(&v["chunks"]["pieces"]);
        let newer = pieces(&v["chunks"]["newerFrame"]["pieces"]);
        let mut reassembler = Reassembler::default();
        reassembler.ingest(&old[0]).unwrap();
        let mut done = None;
        for piece in &newer {
            done = reassembler.ingest(piece).unwrap().or(done);
        }
        let expected = Frame::new(MessageKind::VideoFrame, payload()[..1500].to_vec());
        assert_eq!(done, Some(expected));
    }

    #[test]
    fn rejects_bad_headers() {
        let mut r = Reassembler::default();
        assert_eq!(r.ingest(&Frame::new(MessageKind::VideoChunk, vec![0; 3])), Err(ChunkError::TruncatedHeader { have: 3 }));
        let mut nested = vec![MessageKind::VideoChunk as u8, 0, 0, 0, 1, 0, 0, 0, 1];
        assert_eq!(r.ingest(&Frame::new(MessageKind::VideoChunk, nested.clone())), Err(ChunkError::Nested));
        nested[0] = MessageKind::VideoFrame as u8;
        nested[6] = 5;
        assert_eq!(r.ingest(&Frame::new(MessageKind::VideoChunk, nested)), Err(ChunkError::OutOfRange { index: 5, count: 1 }));
    }

    #[test]
    fn caps_what_it_will_buffer() {
        let mut r = Reassembler::new(10);
        let big = encode(MessageKind::VideoFrame, &[1u8; 40], 1, 8);
        let mut done = None;
        for piece in &big {
            done = r.ingest(piece).unwrap().or(done);
        }
        assert_eq!(done, None);
    }
}
