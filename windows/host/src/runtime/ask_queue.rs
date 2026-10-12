//! A small queue between the lanes that ask the relay for a peer's address and the task that writes the asks to the relay.
//! It holds a few items and, when full, drops the oldest: an ask or an answer that old has been repeated or given up on.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::Notify;

use super::lock::lock_ignoring_poison;

struct Inner<T> {
    items: Mutex<VecDeque<T>>,
    capacity: usize,
    wake: Notify,
    senders: AtomicUsize,
    receiver_gone: AtomicBool,
}

pub struct AskSender<T> {
    inner: Arc<Inner<T>>,
}

pub struct AskReceiver<T> {
    inner: Arc<Inner<T>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Closed;

/// A queue that keeps the newest `capacity` items.
pub fn ask_channel<T>(capacity: usize) -> (AskSender<T>, AskReceiver<T>) {
    let inner = Arc::new(Inner {
        items: Mutex::new(VecDeque::new()),
        capacity: capacity.max(1),
        wake: Notify::new(),
        senders: AtomicUsize::new(1),
        receiver_gone: AtomicBool::new(false),
    });
    (AskSender { inner: inner.clone() }, AskReceiver { inner })
}

impl<T> AskSender<T> {
    /// Queues `item`, dropping the oldest waiting one when the queue is full. Fails once the receiver is gone.
    pub fn send(&self, item: T) -> Result<(), Closed> {
        if self.inner.receiver_gone.load(Ordering::Acquire) {
            return Err(Closed);
        }
        {
            let mut items = lock_ignoring_poison(&self.inner.items);
            if items.len() >= self.inner.capacity {
                items.pop_front();
            }
            items.push_back(item);
        }
        self.inner.wake.notify_one();
        Ok(())
    }
}

impl<T> Clone for AskSender<T> {
    fn clone(&self) -> Self {
        self.inner.senders.fetch_add(1, Ordering::AcqRel);
        Self { inner: self.inner.clone() }
    }
}

impl<T> Drop for AskSender<T> {
    fn drop(&mut self) {
        if self.inner.senders.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.inner.wake.notify_one();
        }
    }
}

impl<T> AskReceiver<T> {
    /// The oldest waiting item, if there is one now.
    pub fn try_recv(&mut self) -> Option<T> {
        lock_ignoring_poison(&self.inner.items).pop_front()
    }

    /// The oldest waiting item, or `None` once every sender is gone and the queue is empty.
    pub async fn recv(&mut self) -> Option<T> {
        loop {
            if let Some(item) = self.try_recv() {
                return Some(item);
            }
            if self.inner.senders.load(Ordering::Acquire) == 0 {
                return None;
            }
            self.inner.wake.notified().await;
        }
    }
}

impl<T> Drop for AskReceiver<T> {
    fn drop(&mut self) {
        self.inner.receiver_gone.store(true, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn a_full_queue_drops_the_oldest_item_and_keeps_the_order() {
        let (sender, mut receiver) = ask_channel(2);
        for item in 1..=3 {
            sender.send(item).expect("open");
        }
        assert_eq!(receiver.recv().await, Some(2));
        assert_eq!(receiver.recv().await, Some(3));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn the_receiver_ends_once_the_last_sender_is_gone_and_the_queue_is_empty() {
        let (sender, mut receiver) = ask_channel(4);
        let other = sender.clone();
        sender.send(1).expect("open");
        drop(sender);
        drop(other);
        assert_eq!(receiver.recv().await, Some(1));
        assert_eq!(receiver.recv().await, None);
    }

    #[test]
    fn sending_fails_once_the_receiver_is_dropped() {
        let (sender, receiver) = ask_channel::<u8>(4);
        drop(receiver);
        assert_eq!(sender.send(1), Err(Closed));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_waiting_receiver_wakes_for_a_new_item() {
        let (sender, mut receiver) = ask_channel(4);
        let waiting = tokio::spawn(async move { receiver.recv().await });
        tokio::task::yield_now().await;
        sender.send(9).expect("open");
        assert_eq!(waiting.await.expect("task"), Some(9));
    }
}
