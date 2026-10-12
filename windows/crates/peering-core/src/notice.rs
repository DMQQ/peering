//! The standing condition the host shows its clients, such as a lock screen or a Windows security prompt. A client keeps
//! a notice on screen until it receives one with no message, so the host sends on change only.

use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::NoticePayload;

#[derive(Debug, Default)]
pub struct NoticeTracker {
    current: Option<NoticePayload>,
}

impl NoticeTracker {
    /// Records the condition now in force. Returns the payload to broadcast when it changed: the new notice, or an empty
    /// one that clears the last. Returns None when nothing changed, so a standing notice is not repeated.
    pub fn update(&mut self, desired: Option<NoticePayload>) -> Option<NoticePayload> {
        if desired == self.current {
            return None;
        }
        self.current.clone_from(&desired);
        Some(desired.unwrap_or(NoticePayload { message: None, symbol: None, locked_display_id: None, code: None }))
    }

    /// The notice a client that connects now has not yet seen.
    pub fn standing(&self) -> Option<&NoticePayload> {
        self.current.as_ref()
    }
}

pub fn notice_frame(payload: &NoticePayload) -> Frame {
    // Derived Serialize over optional strings and a number.
    Frame::new(MessageKind::Notice, serde_json::to_vec(payload).expect("a notice always serialises"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn locked() -> NoticePayload {
        NoticePayload { message: Some("This PC is locked".to_owned()), symbol: Some("lock.fill".to_owned()), locked_display_id: None, code: None }
    }

    fn security_prompt() -> NoticePayload {
        NoticePayload { message: Some("A Windows security prompt is on screen".to_owned()), symbol: None, locked_display_id: None, code: None }
    }

    #[test]
    fn no_condition_and_no_change_sends_nothing() {
        let mut tracker = NoticeTracker::default();
        assert_eq!(tracker.update(None), None);
    }

    #[test]
    fn a_new_condition_is_sent_once() {
        let mut tracker = NoticeTracker::default();
        assert_eq!(tracker.update(Some(locked())), Some(locked()));
        assert_eq!(tracker.update(Some(locked())), None);
    }

    #[test]
    fn a_different_condition_replaces_the_last() {
        let mut tracker = NoticeTracker::default();
        tracker.update(Some(locked()));
        assert_eq!(tracker.update(Some(security_prompt())), Some(security_prompt()));
    }

    #[test]
    fn the_end_of_a_condition_sends_a_notice_with_no_message() {
        let mut tracker = NoticeTracker::default();
        tracker.update(Some(locked()));
        let cleared = tracker.update(None).expect("the clear is sent");
        assert_eq!(cleared.message, None);
        assert_eq!(tracker.standing(), None);
    }

    #[test]
    fn a_client_that_connects_during_a_condition_can_be_told_of_it() {
        let mut tracker = NoticeTracker::default();
        tracker.update(Some(locked()));
        assert_eq!(tracker.standing(), Some(&locked()));
    }

    #[test]
    fn the_frame_is_a_notice_carrying_the_payload() {
        let frame = notice_frame(&locked());
        assert_eq!(frame.kind, MessageKind::Notice);
        let decoded: NoticePayload = serde_json::from_slice(&frame.payload).expect("the payload decodes");
        assert_eq!(decoded, locked());
    }
}
