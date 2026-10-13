use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::lock;
use crate::ports::stream::{ByteStream, StreamError};

type Queue = Arc<Mutex<VecDeque<Vec<u8>>>>;

/// One end of an in-memory connection. Bytes sent on one end are received on the other, in order.
#[derive(Debug)]
pub struct LoopbackStream {
    inbox: Queue,
    outbox: Queue,
    closed: Arc<AtomicBool>,
    peer_public_key: Option<Vec<u8>>,
}

impl LoopbackStream {
    /// Two connected ends. Closing either end closes both.
    pub fn pair() -> (LoopbackStream, LoopbackStream) {
        let a_to_b: Queue = Arc::default();
        let b_to_a: Queue = Arc::default();
        let closed = Arc::new(AtomicBool::new(false));
        let a = LoopbackStream {
            inbox: Arc::clone(&b_to_a),
            outbox: Arc::clone(&a_to_b),
            closed: Arc::clone(&closed),
            peer_public_key: None,
        };
        let b = LoopbackStream {
            inbox: a_to_b,
            outbox: b_to_a,
            closed,
            peer_public_key: None,
        };
        (a, b)
    }

    pub fn with_peer_public_key(mut self, key: Vec<u8>) -> Self {
        self.peer_public_key = Some(key);
        self
    }

    fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }
}

impl ByteStream for LoopbackStream {
    fn send(&mut self, bytes: &[u8]) -> Result<(), StreamError> {
        if self.is_closed() {
            return Err(StreamError::Closed);
        }
        lock(&self.outbox).push_back(bytes.to_vec());
        Ok(())
    }

    fn receive(&mut self) -> Result<Option<Vec<u8>>, StreamError> {
        if let Some(chunk) = lock(&self.inbox).pop_front() {
            return Ok(Some(chunk));
        }
        if self.is_closed() {
            return Err(StreamError::Closed);
        }
        Ok(None)
    }

    fn close(&mut self) {
        self.closed.store(true, Ordering::SeqCst);
    }

    fn peer_public_key(&self) -> Option<Vec<u8>> {
        self.peer_public_key.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use peering_wire::framing::{encode, FrameDecoder, MessageKind};

    #[test]
    fn a_framed_ping_sent_on_one_end_decodes_on_the_other() {
        let (mut host, mut phone) = LoopbackStream::pair();
        host.send(&encode(MessageKind::Ping, b"hello")).unwrap();

        let bytes = phone.receive().unwrap().expect("ping should be queued");
        let mut decoder = FrameDecoder::new();
        decoder.push(&bytes);
        let frame = decoder.next_frame().unwrap().expect("one whole frame");
        assert_eq!(frame.kind, MessageKind::Ping);
        assert_eq!(frame.payload, b"hello".to_vec());
        assert_eq!(phone.receive(), Ok(None));
    }

    #[test]
    fn close_on_one_end_fails_sends_on_the_other() {
        let (mut host, mut phone) = LoopbackStream::pair();
        host.close();
        assert_eq!(phone.send(b"late"), Err(StreamError::Closed));
        assert_eq!(phone.receive(), Err(StreamError::Closed));
    }

    #[test]
    fn peer_public_key_is_reported_when_set() {
        let (host, phone) = LoopbackStream::pair();
        assert_eq!(phone.peer_public_key(), None);
        let keyed = host.with_peer_public_key(vec![4, 1, 2]);
        assert_eq!(keyed.peer_public_key(), Some(vec![4, 1, 2]));
    }
}
