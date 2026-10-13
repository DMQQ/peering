//! One pending video frame per client: a newer frame replaces an older one, except that a keyframe is never lost to a delta.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingFrame {
    pub is_keyframe: bool,
    pub data: Vec<u8>,
}

/// A keyframe is the only frame that can start a decoder from nothing, so an undelivered keyframe
/// outlives a delta that arrives behind it: the delta is worthless without it.
pub fn superseded(waiting: PendingFrame, arriving: PendingFrame) -> PendingFrame {
    if arriving.is_keyframe {
        return arriving;
    }
    if waiting.is_keyframe {
        return waiting;
    }
    arriving
}

#[derive(Debug, Default)]
pub struct LatestFrameSlot {
    pending: Option<PendingFrame>,
}

impl LatestFrameSlot {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns how many frames were discarded to make room: 1 when a frame was waiting, else 0.
    pub fn offer(&mut self, frame: PendingFrame) -> usize {
        match self.pending.take() {
            Some(waiting) => {
                self.pending = Some(superseded(waiting, frame));
                1
            }
            None => {
                self.pending = Some(frame);
                0
            }
        }
    }

    pub fn take(&mut self) -> Option<PendingFrame> {
        self.pending.take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keyframe(tag: u8) -> PendingFrame {
        PendingFrame { is_keyframe: true, data: vec![tag] }
    }

    fn delta(tag: u8) -> PendingFrame {
        PendingFrame { is_keyframe: false, data: vec![tag] }
    }

    #[test]
    fn an_arriving_keyframe_wins_over_a_waiting_delta() {
        assert_eq!(superseded(delta(1), keyframe(2)), keyframe(2));
    }

    #[test]
    fn an_arriving_keyframe_wins_over_a_waiting_keyframe() {
        assert_eq!(superseded(keyframe(1), keyframe(2)), keyframe(2));
    }

    #[test]
    fn a_waiting_keyframe_is_kept_against_an_arriving_delta() {
        assert_eq!(superseded(keyframe(1), delta(2)), keyframe(1));
    }

    #[test]
    fn an_arriving_delta_wins_over_a_waiting_delta() {
        assert_eq!(superseded(delta(1), delta(2)), delta(2));
    }

    #[test]
    fn an_empty_slot_takes_the_first_frame_without_dropping_anything() {
        let mut slot = LatestFrameSlot::new();
        assert_eq!(slot.offer(delta(1)), 0);
        assert_eq!(slot.take(), Some(delta(1)));
    }

    #[test]
    fn a_newer_delta_replaces_a_waiting_delta_and_counts_one_drop() {
        let mut slot = LatestFrameSlot::new();
        slot.offer(delta(1));
        assert_eq!(slot.offer(delta(2)), 1);
        assert_eq!(slot.take(), Some(delta(2)));
        assert_eq!(slot.take(), None);
    }

    #[test]
    fn a_waiting_keyframe_survives_a_burst_of_deltas() {
        let mut slot = LatestFrameSlot::new();
        slot.offer(keyframe(1));
        assert_eq!(slot.offer(delta(2)), 1);
        assert_eq!(slot.offer(delta(3)), 1);
        assert_eq!(slot.take(), Some(keyframe(1)));
        assert_eq!(slot.take(), None);
    }

    #[test]
    fn a_keyframe_replaces_a_waiting_delta() {
        let mut slot = LatestFrameSlot::new();
        slot.offer(delta(1));
        assert_eq!(slot.offer(keyframe(2)), 1);
        assert_eq!(slot.take(), Some(keyframe(2)));
    }

    #[test]
    fn a_delta_after_a_taken_keyframe_starts_a_fresh_slot() {
        let mut slot = LatestFrameSlot::new();
        slot.offer(keyframe(1));
        assert_eq!(slot.take(), Some(keyframe(1)));
        assert_eq!(slot.offer(delta(2)), 0);
        assert_eq!(slot.take(), Some(delta(2)));
    }

    #[test]
    fn taking_an_empty_slot_returns_nothing() {
        assert_eq!(LatestFrameSlot::new().take(), None);
    }
}
