//! Push notifications held for a relay that is not reachable. A message leaves the queue only after the relay socket took
//! it, so a send that fails halfway loses nothing.

use std::collections::VecDeque;

use peering_wire::relay_messages::RelayClientMessage;

/// Older ones are dropped first: a prompt answered long ago is stale.
const MAXIMUM_WAITING: usize = 20;

#[derive(Default)]
pub struct WaitingNotifications {
    queue: VecDeque<RelayClientMessage>,
}

impl WaitingNotifications {
    pub fn hold(&mut self, message: RelayClientMessage) {
        self.queue.push_back(message);
        while self.queue.len() > MAXIMUM_WAITING {
            self.queue.pop_front();
        }
    }

    /// The oldest message, left in the queue until `sent` confirms it went out.
    pub fn next(&self) -> Option<RelayClientMessage> {
        self.queue.front().cloned()
    }

    /// Removes `message` if it is still the oldest. It is not when the cap dropped it while the send was under way.
    pub fn sent(&mut self, message: &RelayClientMessage) {
        if self.queue.front() == Some(message) {
            self.queue.pop_front();
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.queue.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notify(title: &str) -> RelayClientMessage {
        RelayClientMessage::NotifyDevice {
            device_token: "token".to_owned(),
            title: title.to_owned(),
            body: String::new(),
            source: None,
            category: None,
            session_id: None,
            approval_id: None,
        }
    }

    #[test]
    fn a_message_stays_queued_until_it_is_confirmed_sent() {
        let mut waiting = WaitingNotifications::default();
        waiting.hold(notify("a"));
        waiting.hold(notify("b"));
        assert_eq!(waiting.next(), Some(notify("a")));
        assert_eq!(waiting.next(), Some(notify("a")));
        waiting.sent(&notify("a"));
        assert_eq!(waiting.next(), Some(notify("b")));
    }

    #[test]
    fn confirming_a_message_the_cap_already_dropped_removes_nothing() {
        let mut waiting = WaitingNotifications::default();
        waiting.hold(notify("old"));
        for index in 0..MAXIMUM_WAITING {
            waiting.hold(notify(&format!("new {index}")));
        }
        waiting.sent(&notify("old"));
        assert_eq!(waiting.len(), MAXIMUM_WAITING);
        assert_eq!(waiting.next(), Some(notify("new 0")));
    }

    #[test]
    fn the_oldest_are_dropped_past_the_cap() {
        let mut waiting = WaitingNotifications::default();
        for index in 0..MAXIMUM_WAITING + 5 {
            waiting.hold(notify(&index.to_string()));
        }
        assert_eq!(waiting.len(), MAXIMUM_WAITING);
        assert_eq!(waiting.next(), Some(notify("5")));
    }
}
