//! Cutting a message into `videoChunk` frames and putting them back. See docs/protocol/video.md section 5.

use crate::framing::{Frame, MessageKind};
use std::collections::HashMap;
use thiserror::Error;

pub const HEADER_SIZE: usize = 9;
pub const CONTROL_CHUNK_SIZE: usize = 16 * 1024;
pub const DATAGRAM_CHUNK_SIZE: usize = 1024;
pub const MAX_REASSEMBLED: usize = 4 * 1024 * 1024;
/// Data chunks covered by one parity chunk on the datagram lane: one lost chunk in ten is rebuilt, for ten percent more bytes.
pub const PARITY_GROUP_SIZE: usize = 10;
/// Bytes at the front of a parity body that carry the whole payload's length, which the last chunk's length cannot be read from.
const PARITY_LENGTH_SIZE: usize = 4;

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

/// Like [`encode`], then one parity chunk per `group` data chunks, numbered after the data ones. A parity body is the payload's
/// length followed by the XOR of its group's chunk bodies, each zero padded to `chunk_size`. A payload that fits one piece
/// goes out as itself and is not protected.
pub fn encode_with_parity(kind: MessageKind, payload: &[u8], frame_id: u32, chunk_size: usize, group: usize) -> Vec<Frame> {
    let mut frames = encode(kind, payload, frame_id, chunk_size);
    let size = chunk_size.max(1);
    let group = group.max(1);
    if payload.len() <= size || frames.is_empty() {
        return frames;
    }
    let count = payload.len().div_ceil(size);
    let groups = count.div_ceil(group);
    if count + groups > u16::MAX as usize {
        return frames;
    }
    for (g, members) in payload.chunks(size * group).enumerate() {
        let mut body = Vec::with_capacity(HEADER_SIZE + PARITY_LENGTH_SIZE + size);
        body.push(kind as u8);
        body.extend_from_slice(&frame_id.to_be_bytes());
        body.extend_from_slice(&((count + g) as u16).to_be_bytes());
        body.extend_from_slice(&(count as u16).to_be_bytes());
        body.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        let mut xor = vec![0u8; size];
        for part in members.chunks(size) {
            xor.iter_mut().zip(part).for_each(|(x, b)| *x ^= b);
        }
        body.extend_from_slice(&xor);
        frames.push(Frame::new(MessageKind::VideoChunk, body));
    }
    frames
}

/// One per lane: two lanes number their chunks independently, so sharing one would read the other's chunks as a newer picture.
#[derive(Debug)]
pub struct Reassembler {
    max_reassembled: usize,
    frame_id: Option<u32>,
    inner_kind: Option<MessageKind>,
    expected: usize,
    parts: HashMap<usize, Vec<u8>>,
    /// Parity bodies by group, with the payload length they carry.
    parities: HashMap<usize, Vec<u8>>,
    total_length: Option<usize>,
    bytes: usize,
    /// The frame last handed out. Its trailing parity chunks are still on the wire and would each open an empty assembly.
    completed: Option<u32>,
}

/// What a chunk's first bytes say about where it belongs.
struct ChunkHeader {
    inner: MessageKind,
    frame_id: u32,
    index: usize,
    count: usize,
}

impl ChunkHeader {
    /// The header and the body behind it, refusing a chunk that is cut short, nested, out of range or too big.
    fn parse(payload: &[u8]) -> Result<(Self, &[u8]), ChunkError> {
        if payload.len() < HEADER_SIZE {
            return Err(ChunkError::TruncatedHeader { have: payload.len() });
        }
        let inner = MessageKind::from_byte(payload[0]).filter(|k| *k != MessageKind::VideoChunk).ok_or(ChunkError::Nested)?;
        let frame_id = u32::from_be_bytes([payload[1], payload[2], payload[3], payload[4]]);
        let index = u16::from_be_bytes([payload[5], payload[6]]) as usize;
        let count = u16::from_be_bytes([payload[7], payload[8]]) as usize;
        if count == 0 || index >= count + count.div_ceil(PARITY_GROUP_SIZE) {
            return Err(ChunkError::OutOfRange { index, count });
        }
        let body = &payload[HEADER_SIZE..];
        if body.len() > CONTROL_CHUNK_SIZE {
            return Err(ChunkError::Oversized(body.len()));
        }
        Ok((Self { inner, frame_id, index, count }, body))
    }
}

impl Default for Reassembler {
    fn default() -> Self {
        Self::new(MAX_REASSEMBLED)
    }
}

impl Reassembler {
    pub fn new(max_reassembled: usize) -> Self {
        Self { max_reassembled, frame_id: None, inner_kind: None, expected: 0, parts: HashMap::new(), parities: HashMap::new(), total_length: None, bytes: 0, completed: None }
    }

    pub fn ingest(&mut self, frame: &Frame) -> Result<Option<Frame>, ChunkError> {
        let (header, body) = ChunkHeader::parse(&frame.payload)?;
        if self.completed == Some(header.frame_id) {
            return Ok(None);
        }
        if self.frame_id != Some(header.frame_id) {
            self.clear();
            self.frame_id = Some(header.frame_id);
            self.inner_kind = Some(header.inner);
            self.expected = header.count;
        }
        if Some(header.inner) != self.inner_kind || header.count != self.expected {
            return Ok(None);
        }
        let group = if header.index >= header.count {
            self.keep_parity(header.index - header.count, body);
            header.index - header.count
        } else {
            if !self.parts.contains_key(&header.index) {
                self.bytes += body.len();
                self.parts.insert(header.index, body.to_vec());
            }
            header.index / PARITY_GROUP_SIZE
        };
        if self.bytes > self.max_reassembled {
            self.clear();
            return Ok(None);
        }
        if self.parts.len() != self.expected {
            self.recover(group);
        }
        if self.parts.len() != self.expected {
            return Ok(None);
        }
        Ok(Some(self.assemble(header.inner)))
    }

    fn keep_parity(&mut self, group: usize, body: &[u8]) {
        if body.len() <= PARITY_LENGTH_SIZE {
            return;
        }
        let (length, xor) = body.split_at(PARITY_LENGTH_SIZE);
        self.total_length = Some(u32::from_be_bytes([length[0], length[1], length[2], length[3]]) as usize);
        self.parities.insert(group, xor.to_vec());
    }

    /// Rebuilds the one missing chunk of `group` once its parity has arrived, which is the only group the chunk just ingested
    /// can have changed. Two missing in a group cannot be told apart, so that group is left, and the picture is lost as it was
    /// before parity existed.
    fn recover(&mut self, group: usize) {
        let (Some(total), Some(xor)) = (self.total_length, self.parities.get(&group)) else { return };
        let first = group * PARITY_GROUP_SIZE;
        let members = first..(first + PARITY_GROUP_SIZE).min(self.expected);
        let mut missing = members.clone().filter(|i| !self.parts.contains_key(i));
        let (Some(lost), None) = (missing.next(), missing.next()) else { return };
        let mut rebuilt = xor.clone();
        for present in members.filter(|i| *i != lost) {
            rebuilt.iter_mut().zip(&self.parts[&present]).for_each(|(x, b)| *x ^= b);
        }
        if lost + 1 == self.expected {
            let Some(length) = total.checked_sub((self.expected - 1) * xor.len()) else { return };
            rebuilt.truncate(length);
        }
        self.bytes += rebuilt.len();
        self.parts.insert(lost, rebuilt);
    }

    /// Joins the parts in order and starts over.
    fn assemble(&mut self, kind: MessageKind) -> Frame {
        let mut assembled = Vec::with_capacity(self.bytes);
        for i in 0..self.expected {
            assembled.extend_from_slice(&self.parts[&i]);
        }
        let finished = self.frame_id;
        self.clear();
        self.completed = finished;
        Frame::new(kind, assembled)
    }

    fn clear(&mut self) {
        self.frame_id = None;
        self.inner_kind = None;
        self.expected = 0;
        self.parts.clear();
        self.parities.clear();
        self.total_length = None;
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

    fn parity_payload() -> Vec<u8> {
        (0..10).collect()
    }

    fn with_parity() -> Vec<Frame> {
        encode_with_parity(MessageKind::VideoFrame, &parity_payload(), 7, 4, 2)
    }

    fn feed(frames: &[&Frame]) -> Option<Frame> {
        let mut reassembler = Reassembler::default();
        let mut done = None;
        for frame in frames {
            done = reassembler.ingest(frame).unwrap().or(done);
        }
        done
    }

    #[test]
    fn parity_bodies_are_the_length_then_the_xor_of_the_group() {
        let frames = with_parity();
        assert_eq!(frames.len(), 5);
        let kind = MessageKind::VideoFrame as u8;
        assert_eq!(frames[3].payload, [&[kind, 0, 0, 0, 7, 0, 3, 0, 3][..], &[0, 0, 0, 10, 4, 4, 4, 4]].concat());
        assert_eq!(frames[4].payload, [&[kind, 0, 0, 0, 7, 0, 4, 0, 3][..], &[0, 0, 0, 10, 8, 9, 0, 0]].concat());
    }

    /// Eleven chunks of two bytes, the last holding one, so the first group is full and the second is the short last chunk alone.
    fn eleven_chunks() -> (Vec<u8>, Vec<Frame>) {
        let payload: Vec<u8> = (0..21).collect();
        let frames = encode_with_parity(MessageKind::VideoFrame, &payload, 7, 2, PARITY_GROUP_SIZE);
        assert_eq!(frames.len(), 13);
        (payload, frames)
    }

    #[test]
    fn any_single_lost_chunk_is_rebuilt_from_its_groups_parity() {
        let (payload, frames) = eleven_chunks();
        for lost in 0..11 {
            let kept: Vec<&Frame> = frames.iter().enumerate().filter(|(i, _)| *i != lost).map(|(_, f)| f).collect();
            assert_eq!(feed(&kept), Some(Frame::new(MessageKind::VideoFrame, payload.clone())), "lost chunk {lost}");
        }
    }

    #[test]
    fn parity_arriving_first_still_rebuilds() {
        let (payload, frames) = eleven_chunks();
        let mut order: Vec<&Frame> = vec![&frames[11], &frames[12]];
        order.extend(frames[..11].iter().enumerate().filter(|(i, _)| *i != 4).map(|(_, f)| f));
        assert_eq!(feed(&order), Some(Frame::new(MessageKind::VideoFrame, payload)));
    }

    #[test]
    fn two_lost_chunks_in_one_group_are_not_rebuilt() {
        let (_, frames) = eleven_chunks();
        let kept: Vec<&Frame> = frames.iter().enumerate().filter(|(i, _)| *i != 2 && *i != 5).map(|(_, f)| f).collect();
        assert_eq!(feed(&kept), None);
    }

    #[test]
    fn a_whole_frame_ignores_its_parity() {
        let (payload, frames) = eleven_chunks();
        let all: Vec<&Frame> = frames.iter().collect();
        assert_eq!(feed(&all), Some(Frame::new(MessageKind::VideoFrame, payload)));
    }

    #[test]
    fn a_payload_that_fits_one_piece_carries_no_parity() {
        assert_eq!(encode_with_parity(MessageKind::Ping, b"abc", 1, 1024, 10).len(), 1);
    }

    #[test]
    fn a_realistic_frame_survives_one_loss_per_group() {
        let payload: Vec<u8> = (0..25_000u32).map(|i| (i * 31 % 251) as u8).collect();
        let frames = encode_with_parity(MessageKind::VideoFrame, &payload, 9, DATAGRAM_CHUNK_SIZE, PARITY_GROUP_SIZE);
        let count = payload.len().div_ceil(DATAGRAM_CHUNK_SIZE);
        assert_eq!(frames.len(), count + count.div_ceil(PARITY_GROUP_SIZE));
        let kept: Vec<&Frame> = frames.iter().enumerate().filter(|(i, _)| i % PARITY_GROUP_SIZE != 3 || *i >= count).map(|(_, f)| f).collect();
        assert_eq!(feed(&kept), Some(Frame::new(MessageKind::VideoFrame, payload)));
    }

    #[test]
    fn a_completed_frames_trailing_parity_does_not_open_a_new_assembly() {
        let (payload, frames) = eleven_chunks();
        let mut reassembler = Reassembler::default();
        let mut done = None;
        for frame in &frames {
            done = reassembler.ingest(frame).unwrap().or(done);
        }
        assert_eq!(done, Some(Frame::new(MessageKind::VideoFrame, payload)));
        assert_eq!(reassembler.frame_id, None);
    }

    #[test]
    fn a_late_parity_does_not_wipe_the_next_frames_progress() {
        let (_, old) = eleven_chunks();
        let newer = encode_with_parity(MessageKind::VideoFrame, &(0..21).collect::<Vec<u8>>(), 8, 2, PARITY_GROUP_SIZE);
        let mut reassembler = Reassembler::default();
        for frame in &old[..11] {
            reassembler.ingest(frame).unwrap();
        }
        reassembler.ingest(&newer[0]).unwrap();
        reassembler.ingest(&old[11]).unwrap();
        assert_eq!(reassembler.frame_id, Some(8));
        assert_eq!(reassembler.parts.len(), 1);
    }
}
