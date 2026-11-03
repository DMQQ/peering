//! One answer as the phone is sent it: a head, bodies of at most `CHUNK_BYTES`, then an end. Mirrors `PreviewTransfer.swift`.

use peering_wire::preview::{PreviewProxyEvent, CHUNK_BYTES, MAX_RESPONSE_BYTES};

use super::exchange::Piece;
use super::policy::filtered_response_headers;

pub struct Transfer {
    id: u32,
    pending: Vec<u8>,
    received: usize,
    finished: bool,
}

impl Transfer {
    pub fn new(id: u32) -> Self {
        Self { id, pending: Vec::new(), received: 0, finished: false }
    }

    /// Set once the end has been sent; nothing more follows.
    pub fn is_finished(&self) -> bool {
        self.finished
    }

    pub fn accept(&mut self, pieces: Vec<Piece>) -> Vec<PreviewProxyEvent> {
        let mut events = Vec::new();
        for piece in pieces {
            if self.finished {
                break;
            }
            match piece {
                Piece::Head { status, headers } => {
                    events.push(PreviewProxyEvent::Head { id: self.id, status, headers: filtered_response_headers(headers) });
                }
                Piece::Data(data) => self.data(&data, &mut events),
                Piece::End => self.end(false, &mut events),
            }
        }
        events
    }

    fn data(&mut self, data: &[u8], events: &mut Vec<PreviewProxyEvent>) {
        let room = MAX_RESPONSE_BYTES - self.received;
        let kept = &data[..data.len().min(room)];
        self.received += kept.len();
        self.pending.extend_from_slice(kept);
        self.flush(false, events);
        if kept.len() < data.len() {
            self.end(true, events);
        }
    }

    fn end(&mut self, truncated: bool, events: &mut Vec<PreviewProxyEvent>) {
        self.flush(true, events);
        events.push(PreviewProxyEvent::End { id: self.id, truncated });
        self.finished = true;
    }

    fn flush(&mut self, all: bool, events: &mut Vec<PreviewProxyEvent>) {
        while self.pending.len() >= CHUNK_BYTES || (all && !self.pending.is_empty()) {
            let size = self.pending.len().min(CHUNK_BYTES);
            let data: Vec<u8> = self.pending.drain(..size).collect();
            events.push(PreviewProxyEvent::Body { id: self.id, data });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sizes(events: &[PreviewProxyEvent]) -> Vec<usize> {
        events.iter().filter_map(|event| if let PreviewProxyEvent::Body { data, .. } = event { Some(data.len()) } else { None }).collect()
    }

    #[test]
    fn a_body_is_sent_in_chunks_and_the_remainder_at_the_end() {
        let mut transfer = Transfer::new(4);
        let events = transfer.accept(vec![Piece::Data(vec![1; CHUNK_BYTES + 10]), Piece::End]);
        assert_eq!(sizes(&events), [CHUNK_BYTES, 10]);
        assert_eq!(events.last(), Some(&PreviewProxyEvent::End { id: 4, truncated: false }));
        assert!(transfer.is_finished());
    }

    #[test]
    fn a_body_past_the_limit_is_cut_and_marked_truncated() {
        let mut transfer = Transfer::new(1);
        let events = transfer.accept(vec![Piece::Data(vec![0; MAX_RESPONSE_BYTES + 1]), Piece::Data(vec![0; 5]), Piece::End]);
        assert_eq!(sizes(&events).iter().sum::<usize>(), MAX_RESPONSE_BYTES);
        assert_eq!(events.last(), Some(&PreviewProxyEvent::End { id: 1, truncated: true }));
    }

    #[test]
    fn the_head_carries_only_the_allowed_headers() {
        let headers = vec![
            peering_wire::preview::PreviewHeader { name: "Set-Cookie".to_owned(), value: "a".to_owned() },
            peering_wire::preview::PreviewHeader { name: "Location".to_owned(), value: "/b".to_owned() },
        ];
        let events = Transfer::new(2).accept(vec![Piece::Head { status: 302, headers }]);
        let [PreviewProxyEvent::Head { status: 302, headers, .. }] = events.as_slice() else { panic!("a head") };
        assert_eq!(headers.len(), 1);
    }
}
