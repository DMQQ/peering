//! Per direction video keys and ChaCha20-Poly1305 datagram sealing. See docs/protocol/video.md section 3.

use crate::chunks::{self, Reassembler};
use crate::framing::{Frame, FrameDecoder, MessageKind};
use crate::replay::ReplayWindow;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use thiserror::Error;

pub const TOKEN_SIZE: usize = 16;
pub const COUNTER_SIZE: usize = 8;
pub const TAG_SIZE: usize = 16;
pub const MIN_FORWARDED_SIZE: usize = COUNTER_SIZE + TAG_SIZE;
pub const MAX_DATAGRAM_SIZE: usize = 2048;
pub const SECRET_SIZE: usize = 32;
const SALT: &[u8] = b"pl.dmq.peering.video-datagram";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    ClientToHost,
    HostToClient,
}

impl Direction {
    fn label(self) -> &'static [u8] {
        match self {
            Direction::ClientToHost => b"video client-to-host",
            Direction::HostToClient => b"video host-to-client",
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SealError {
    #[error("datagram of {have} bytes is shorter than {need}")]
    Truncated { have: usize, need: usize },
    #[error("datagram of {0} bytes is larger than the protocol allows")]
    Oversized(usize),
    #[error("datagram did not authenticate")]
    AuthenticationFailed,
    #[error("authenticated datagram did not hold a frame")]
    MalformedPayload,
    #[error("the video secret must be 32 bytes")]
    BadSecret,
}

pub fn derive_key(secret: &[u8], direction: Direction) -> Result<[u8; 32], SealError> {
    if secret.len() != SECRET_SIZE {
        return Err(SealError::BadSecret);
    }
    let mut key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(SALT), secret).expand(direction.label(), &mut key).map_err(|_| SealError::BadSecret)?;
    Ok(key)
}

/// The nonce is four zero bytes then the counter, so a counter must never repeat under one key.
fn nonce(counter: u64) -> Nonce {
    let mut bytes = [0u8; 12];
    bytes[4..].copy_from_slice(&counter.to_be_bytes());
    *Nonce::from_slice(&bytes)
}

pub struct Sealer {
    cipher: ChaCha20Poly1305,
    token: [u8; TOKEN_SIZE],
    counter: u64,
    frame_id: u32,
}

impl Sealer {
    pub fn new(secret: &[u8], direction: Direction, token: [u8; TOKEN_SIZE]) -> Result<Self, SealError> {
        let key = derive_key(secret, direction)?;
        Ok(Self { cipher: ChaCha20Poly1305::new(Key::from_slice(&key)), token, counter: 0, frame_id: 0 })
    }

    /// A datagram of only the token: registers this end's address with the relay, forwarded nowhere.
    pub fn bind_datagram(&self) -> Vec<u8> {
        self.token.to_vec()
    }

    /// Cuts the message into datagram sized pieces and seals each. Returns nothing if the payload cannot be chunked.
    pub fn seal(&mut self, kind: MessageKind, payload: &[u8]) -> Vec<Vec<u8>> {
        self.frame_id = self.frame_id.wrapping_add(1);
        chunks::encode(kind, payload, self.frame_id, chunks::DATAGRAM_CHUNK_SIZE)
            .iter()
            .map(|piece| self.seal_frame(&piece.encode()))
            .collect()
    }

    fn seal_frame(&mut self, plaintext: &[u8]) -> Vec<u8> {
        self.counter += 1;
        let boxed = self.cipher.encrypt(&nonce(self.counter), plaintext).expect("encryption of a bounded buffer cannot fail");
        let mut out = Vec::with_capacity(TOKEN_SIZE + COUNTER_SIZE + boxed.len());
        out.extend_from_slice(&self.token);
        out.extend_from_slice(&self.counter.to_be_bytes());
        out.extend_from_slice(&boxed);
        out
    }
}

/// One per lane: it owns the replay window and the partial picture.
pub struct Opener {
    cipher: ChaCha20Poly1305,
    window: ReplayWindow,
    chunks: Reassembler,
}

impl Opener {
    pub fn new(secret: &[u8], direction: Direction) -> Result<Self, SealError> {
        let key = derive_key(secret, direction)?;
        Ok(Self { cipher: ChaCha20Poly1305::new(Key::from_slice(&key)), window: ReplayWindow::new(), chunks: Reassembler::default() })
    }

    /// `datagram` is what the relay forwarded: counter, ciphertext, tag. `Ok(None)` is a replay or an unfinished picture.
    pub fn open(&mut self, datagram: &[u8]) -> Result<Option<Frame>, SealError> {
        if datagram.len() < MIN_FORWARDED_SIZE {
            return Err(SealError::Truncated { have: datagram.len(), need: MIN_FORWARDED_SIZE });
        }
        if datagram.len() > MAX_DATAGRAM_SIZE {
            return Err(SealError::Oversized(datagram.len()));
        }
        let mut counter_bytes = [0u8; COUNTER_SIZE];
        counter_bytes.copy_from_slice(&datagram[..COUNTER_SIZE]);
        let counter = u64::from_be_bytes(counter_bytes);
        if !self.window.accepts(counter) {
            return Ok(None);
        }
        let plaintext = self
            .cipher
            .decrypt(&nonce(counter), &datagram[COUNTER_SIZE..])
            .map_err(|_| SealError::AuthenticationFailed)?;
        self.window.commit(counter);

        let mut decoder = FrameDecoder::new();
        decoder.push(&plaintext);
        let frame = decoder.next_frame().ok().flatten().ok_or(SealError::MalformedPayload)?;
        if frame.kind != MessageKind::VideoChunk {
            return Ok(Some(frame));
        }
        self.chunks.ingest(&frame).map_err(|_| SealError::MalformedPayload)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;

    fn secret() -> Vec<u8> {
        (0..32u32).map(|i| ((i * 31 + 7) & 0xFF) as u8).collect()
    }

    fn token() -> [u8; 16] {
        let mut t = [0u8; 16];
        for (i, b) in t.iter_mut().enumerate() {
            *b = ((i * 7 + 1) & 0xFF) as u8;
        }
        t
    }

    #[test]
    fn derived_keys_match_the_vector() {
        let v = &load("crypto.json")["hkdf"];
        assert_eq!(hex::encode(derive_key(&secret(), Direction::ClientToHost).unwrap()), v["clientToHostKey"].as_str().unwrap());
        assert_eq!(hex::encode(derive_key(&secret(), Direction::HostToClient).unwrap()), v["hostToClientKey"].as_str().unwrap());
    }

    #[test]
    fn a_sealed_ping_matches_the_vector_byte_for_byte() {
        let v = &load("crypto.json")["sealedDatagram"];
        let mut sealer = Sealer::new(&secret(), Direction::HostToClient, token()).unwrap();
        let out = sealer.seal(MessageKind::Ping, br#"{"sequence":1}"#);
        assert_eq!(out.len(), 1);
        assert_eq!(hex::encode(&out[0]), v["asSent"].as_str().unwrap());
    }

    #[test]
    fn opens_what_the_relay_forwards() {
        let mut sealer = Sealer::new(&secret(), Direction::HostToClient, token()).unwrap();
        let mut opener = Opener::new(&secret(), Direction::HostToClient).unwrap();
        let sealed = sealer.seal(MessageKind::Ping, b"{}");
        let frame = opener.open(&sealed[0][TOKEN_SIZE..]).unwrap().unwrap();
        assert_eq!(frame, Frame::new(MessageKind::Ping, b"{}".to_vec()));
    }

    #[test]
    fn a_large_message_crosses_in_chunks_and_a_replay_is_dropped() {
        let mut sealer = Sealer::new(&secret(), Direction::HostToClient, token()).unwrap();
        let mut opener = Opener::new(&secret(), Direction::HostToClient).unwrap();
        let picture: Vec<u8> = (0..5000).map(|i| (i % 253) as u8).collect();
        let datagrams = sealer.seal(MessageKind::VideoFrame, &picture);
        assert!(datagrams.len() > 4);
        assert!(datagrams.iter().all(|d| d.len() <= 1100));
        let mut done = None;
        for d in &datagrams {
            done = opener.open(&d[TOKEN_SIZE..]).unwrap().or(done);
        }
        assert_eq!(done, Some(Frame::new(MessageKind::VideoFrame, picture)));
        assert_eq!(opener.open(&datagrams[0][TOKEN_SIZE..]).unwrap(), None);
    }

    #[test]
    fn rejects_tampering_the_wrong_direction_and_bad_sizes() {
        let mut sealer = Sealer::new(&secret(), Direction::HostToClient, token()).unwrap();
        let sealed = sealer.seal(MessageKind::Ping, b"{}").remove(0);
        let mut tampered = sealed[TOKEN_SIZE..].to_vec();
        *tampered.last_mut().unwrap() ^= 1;
        let mut opener = Opener::new(&secret(), Direction::HostToClient).unwrap();
        assert_eq!(opener.open(&tampered), Err(SealError::AuthenticationFailed));
        let mut wrong = Opener::new(&secret(), Direction::ClientToHost).unwrap();
        assert_eq!(wrong.open(&sealed[TOKEN_SIZE..]), Err(SealError::AuthenticationFailed));
        assert_eq!(opener.open(&[0; 10]), Err(SealError::Truncated { have: 10, need: 24 }));
        assert_eq!(opener.open(&vec![0; 3000]), Err(SealError::Oversized(3000)));
        assert!(matches!(Sealer::new(&[0; 5], Direction::HostToClient, token()), Err(SealError::BadSecret)));
    }

    #[test]
    fn the_bind_datagram_is_the_bare_token() {
        let sealer = Sealer::new(&secret(), Direction::ClientToHost, token()).unwrap();
        assert_eq!(sealer.bind_datagram(), token().to_vec());
    }
}
