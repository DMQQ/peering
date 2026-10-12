//! The policy for what a connection may have waiting to be written. A peer that stops reading must not grow the host's
//! memory: stale picture data is dropped oldest first, and a queue that still passes its high-water mark ends the
//! connection.

use std::collections::VecDeque;

use peering_wire::framing::{Frame, MessageKind};

/// Waiting picture and sound data past this is dropped, oldest first.
pub const DROPPABLE_HIGH_WATER_BYTES: usize = 4 * 1024 * 1024;
/// Everything waiting past this ends the connection: the peer is not reading.
pub const TOTAL_HIGH_WATER_BYTES: usize = 16 * 1024 * 1024;
pub const TOTAL_HIGH_WATER_ITEMS: usize = 4096;

pub trait Queued {
    fn weight(&self) -> usize;
    /// True for data that is worthless once a newer copy exists, such as a video frame.
    fn droppable(&self) -> bool;
}

impl Queued for Frame {
    fn weight(&self) -> usize {
        self.payload.len() + 1
    }

    fn droppable(&self) -> bool {
        matches!(self.kind, MessageKind::VideoFrame | MessageKind::VideoChunk | MessageKind::AudioFrame)
    }
}

impl Queued for Vec<u8> {
    fn weight(&self) -> usize {
        self.len()
    }

    fn droppable(&self) -> bool {
        true
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pushed {
    Queued { dropped: usize },
    /// The queue passed its high-water mark. The connection must end.
    Overflowed,
}

#[derive(Debug)]
pub struct OutboundQueue<T: Queued> {
    items: VecDeque<T>,
    bytes: usize,
    droppable_bytes: usize,
    droppable_limit: usize,
    total_limit: usize,
    item_limit: usize,
}

impl<T: Queued> OutboundQueue<T> {
    pub fn new() -> Self {
        Self::with_limits(DROPPABLE_HIGH_WATER_BYTES, TOTAL_HIGH_WATER_BYTES, TOTAL_HIGH_WATER_ITEMS)
    }

    pub fn with_limits(droppable_limit: usize, total_limit: usize, item_limit: usize) -> Self {
        Self { items: VecDeque::new(), bytes: 0, droppable_bytes: 0, droppable_limit, total_limit, item_limit }
    }

    pub fn push(&mut self, item: T) -> Pushed {
        self.bytes += item.weight();
        if item.droppable() {
            self.droppable_bytes += item.weight();
        }
        self.items.push_back(item);
        let dropped = self.drop_stale();
        if self.bytes > self.total_limit || self.items.len() > self.item_limit {
            return Pushed::Overflowed;
        }
        Pushed::Queued { dropped }
    }

    pub fn pop(&mut self) -> Option<T> {
        let item = self.items.pop_front()?;
        self.bytes -= item.weight();
        if item.droppable() {
            self.droppable_bytes -= item.weight();
        }
        Some(item)
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    fn drop_stale(&mut self) -> usize {
        let mut dropped = 0;
        // The newest item stays even when it alone is over the limit: the next push replaces it.
        while self.droppable_bytes > self.droppable_limit {
            let newest = self.items.len() - 1;
            let Some(oldest) = self.items.iter().take(newest).position(Queued::droppable) else {
                break;
            };
            if let Some(removed) = self.items.remove(oldest) {
                self.bytes -= removed.weight();
                self.droppable_bytes -= removed.weight();
                dropped += 1;
            }
        }
        dropped
    }
}

impl<T: Queued> Default for OutboundQueue<T> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn video(size: usize) -> Frame {
        Frame::new(MessageKind::VideoFrame, vec![0; size])
    }

    fn control(size: usize) -> Frame {
        Frame::new(MessageKind::Command, vec![0; size])
    }

    #[test]
    fn frames_come_out_in_the_order_they_went_in() {
        let mut queue = OutboundQueue::new();
        queue.push(control(1));
        queue.push(video(2));
        assert_eq!(queue.pop().map(|frame| frame.kind), Some(MessageKind::Command));
        assert_eq!(queue.pop().map(|frame| frame.kind), Some(MessageKind::VideoFrame));
        assert!(queue.pop().is_none());
    }

    #[test]
    fn the_oldest_video_frames_are_dropped_first() {
        let mut queue = OutboundQueue::with_limits(25, 1000, 100);
        for tag in 1..=3u8 {
            queue.push(Frame::new(MessageKind::VideoFrame, vec![tag; 10]));
        }
        let outcome = queue.push(Frame::new(MessageKind::VideoFrame, vec![4; 10]));
        assert_eq!(outcome, Pushed::Queued { dropped: 1 });
        assert_eq!(queue.pop().map(|frame| frame.payload[0]), Some(3));
        assert_eq!(queue.pop().map(|frame| frame.payload[0]), Some(4));
    }

    #[test]
    fn control_frames_are_never_dropped_to_make_room_for_video() {
        let mut queue = OutboundQueue::with_limits(15, 1000, 100);
        queue.push(control(50));
        queue.push(video(10));
        queue.push(video(10));
        assert_eq!(queue.len(), 2);
        assert_eq!(queue.pop().map(|frame| frame.kind), Some(MessageKind::Command));
    }

    #[test]
    fn a_peer_that_never_reads_overflows_on_control_bytes() {
        let mut queue = OutboundQueue::with_limits(100, 100, 100);
        assert!(matches!(queue.push(control(60)), Pushed::Queued { .. }));
        assert_eq!(queue.push(control(60)), Pushed::Overflowed);
    }

    #[test]
    fn too_many_waiting_items_overflow_even_when_small() {
        let mut queue = OutboundQueue::with_limits(100, 10_000, 3);
        for _ in 0..3 {
            assert!(matches!(queue.push(control(1)), Pushed::Queued { .. }));
        }
        assert_eq!(queue.push(control(1)), Pushed::Overflowed);
    }

    #[test]
    fn popping_releases_the_bytes() {
        let mut queue = OutboundQueue::with_limits(100, 100, 100);
        queue.push(control(60));
        queue.pop();
        assert!(matches!(queue.push(control(60)), Pushed::Queued { .. }));
    }

    #[test]
    fn datagrams_are_all_droppable() {
        let mut queue = OutboundQueue::<Vec<u8>>::with_limits(20, 1000, 100);
        queue.push(vec![1; 10]);
        queue.push(vec![2; 10]);
        assert_eq!(queue.push(vec![3; 10]), Pushed::Queued { dropped: 1 });
        assert_eq!(queue.pop(), Some(vec![2; 10]));
    }
}
