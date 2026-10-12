//! A queue between the tasks that produce data for a connection and the task that writes it. Unlike an unbounded
//! channel it has a high-water mark: see `peering_core::outbound` for the policy.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_core::outbound::{OutboundQueue, Pushed, Queued};
use peering_wire::framing::Frame;
use tokio::sync::{watch, Notify};

struct Inner<T: Queued> {
    queue: Mutex<OutboundQueue<T>>,
    wake: Notify,
    senders: AtomicUsize,
    receiver_gone: AtomicBool,
    overflowed: watch::Sender<bool>,
}

impl<T: Queued> Inner<T> {
    fn queue(&self) -> MutexGuard<'_, OutboundQueue<T>> {
        self.queue.lock().unwrap_or_else(PoisonError::into_inner)
    }

    async fn wait_for_overflow(&self) {
        let mut watcher = self.overflowed.subscribe();
        let _reached = watcher.wait_for(|overflowed| *overflowed).await;
    }
}

/// The producing end. Clone it freely; the receiver ends once the last clone is gone.
pub struct Outbound<T: Queued> {
    inner: Arc<Inner<T>>,
}

pub type FrameSender = Outbound<Frame>;

pub struct OutboundReceiver<T: Queued> {
    inner: Arc<Inner<T>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Closed;

pub fn outbound<T: Queued>() -> (Outbound<T>, OutboundReceiver<T>) {
    outbound_with(OutboundQueue::new())
}

fn outbound_with<T: Queued>(queue: OutboundQueue<T>) -> (Outbound<T>, OutboundReceiver<T>) {
    let inner = Arc::new(Inner {
        queue: Mutex::new(queue),
        wake: Notify::new(),
        senders: AtomicUsize::new(1),
        receiver_gone: AtomicBool::new(false),
        overflowed: watch::channel(false).0,
    });
    (Outbound { inner: inner.clone() }, OutboundReceiver { inner })
}

impl<T: Queued> Outbound<T> {
    /// Queues `item`. Fails once the receiver is gone or the queue has passed its high-water mark.
    pub fn send(&self, item: T) -> Result<(), Closed> {
        if self.is_closed() {
            return Err(Closed);
        }
        let pushed = self.inner.queue().push(item);
        if pushed == Pushed::Overflowed {
            self.inner.overflowed.send_replace(true);
        }
        self.inner.wake.notify_one();
        if pushed == Pushed::Overflowed { Err(Closed) } else { Ok(()) }
    }

    pub fn is_closed(&self) -> bool {
        self.inner.receiver_gone.load(Ordering::Acquire) || *self.inner.overflowed.borrow()
    }
}

impl<T: Queued> Clone for Outbound<T> {
    fn clone(&self) -> Self {
        self.inner.senders.fetch_add(1, Ordering::AcqRel);
        Self { inner: self.inner.clone() }
    }
}

impl<T: Queued> Drop for Outbound<T> {
    fn drop(&mut self) {
        if self.inner.senders.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.inner.wake.notify_one();
        }
    }
}

impl<T: Queued> OutboundReceiver<T> {
    /// The next item, or `None` once every sender is gone and the queue is empty, or the queue overflowed.
    pub async fn recv(&mut self) -> Option<T> {
        loop {
            if *self.inner.overflowed.borrow() {
                return None;
            }
            if let Some(item) = self.inner.queue().pop() {
                return Some(item);
            }
            if self.inner.senders.load(Ordering::Acquire) == 0 {
                return None;
            }
            self.inner.wake.notified().await;
        }
    }

    /// Resolves when the queue has passed its high-water mark, so a task blocked on a peer that is not reading can stop.
    pub async fn overflowed(&self) {
        self.inner.wait_for_overflow().await;
    }
}

impl<T: Queued> Outbound<T> {
    /// Resolves when the queue has passed its high-water mark, for the task that owns the connection to end it.
    pub async fn overflowed(&self) {
        self.inner.wait_for_overflow().await;
    }
}

impl<T: Queued> Drop for OutboundReceiver<T> {
    fn drop(&mut self) {
        self.inner.receiver_gone.store(true, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use peering_wire::framing::MessageKind;

    use super::*;

    fn command(size: usize) -> Frame {
        Frame::new(MessageKind::Command, vec![0; size])
    }

    #[tokio::test(flavor = "current_thread")]
    async fn items_arrive_in_order_and_the_receiver_ends_with_the_last_sender() {
        let (sender, mut receiver) = outbound::<Frame>();
        let other = sender.clone();
        sender.send(command(1)).expect("open");
        other.send(command(2)).expect("open");
        drop(sender);
        drop(other);
        assert_eq!(receiver.recv().await.map(|frame| frame.payload.len()), Some(1));
        assert_eq!(receiver.recv().await.map(|frame| frame.payload.len()), Some(2));
        assert!(receiver.recv().await.is_none());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_waiting_receiver_wakes_for_a_new_item() {
        let (sender, mut receiver) = outbound::<Frame>();
        let waiting = tokio::spawn(async move { receiver.recv().await.map(|frame| frame.payload.len()) });
        tokio::task::yield_now().await;
        sender.send(command(7)).expect("open");
        assert_eq!(waiting.await.expect("task"), Some(7));
    }

    #[test]
    fn sending_fails_once_the_receiver_is_dropped() {
        let (sender, receiver) = outbound::<Frame>();
        drop(receiver);
        assert!(sender.is_closed());
        assert_eq!(sender.send(command(1)), Err(Closed));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_queue_past_the_high_water_mark_closes_the_connection() {
        let (sender, mut receiver) = outbound_with(OutboundQueue::<Frame>::with_limits(100, 100, 100));
        sender.send(command(60)).expect("room");
        assert_eq!(sender.send(command(60)), Err(Closed));
        assert!(sender.is_closed());
        receiver.overflowed().await;
        sender.overflowed().await;
        assert!(receiver.recv().await.is_none());
    }

    #[test]
    fn a_stalled_peer_loses_video_but_keeps_the_connection() {
        let (sender, _receiver) = outbound_with(OutboundQueue::<Frame>::with_limits(30, 1000, 100));
        for _ in 0..50 {
            sender.send(Frame::new(MessageKind::VideoFrame, vec![0; 10])).expect("video is dropped, not refused");
        }
        assert!(!sender.is_closed());
    }
}
