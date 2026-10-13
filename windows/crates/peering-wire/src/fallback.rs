//! When video leaves the primary lane for the control channel, and when it returns. Times are monotonic seconds, never a wall clock.

pub const SILENCE_BEFORE_FALLBACK: f64 = 3.0;
pub const CONTROL_HEALTH_WINDOW: f64 = 5.0;
pub const REQUEST_REPEAT_INTERVAL: f64 = 5.0;
pub const MIN_FALLBACK_HOLD: f64 = 5.0;
pub const PRIMARY_PICTURES_FOR_RETURN: u32 = 2;

/// Host side: video on the control lane is rate capped, and the primary lane is probed with keyframes
/// so the client can see when it has recovered.
pub const CONTROL_LANE_CAP_KBPS: u32 = 2_000;
pub const PRIMARY_PROBE_INTERVAL: f64 = 4.0;

/// How long the host keeps a frame "recent" enough to serve a fallback request.
const HOST_PRODUCTION_WINDOW: f64 = 5.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    None,
    UseControlChannel,
    UsePrimaryTransport,
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct ClientFallbackPolicy {
    is_fallback: bool,
    last_request_at: Option<f64>,
    fell_back_at: f64,
    primary_pictures: u32,
}

impl ClientFallbackPolicy {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_fallback(&self) -> bool {
        self.is_fallback
    }

    pub fn advance(
        &mut self,
        now: f64,
        last_picture_at: Option<f64>,
        last_control_reply_at: Option<f64>,
        applies: bool,
    ) -> Decision {
        if !applies {
            return Decision::None;
        }
        if self.is_fallback {
            self.advance_in_fallback(now, last_picture_at)
        } else {
            self.advance_on_primary(now, last_picture_at, last_control_reply_at)
        }
    }

    pub fn note_primary_picture(&mut self) {
        if self.is_fallback {
            self.primary_pictures += 1;
        }
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    fn advance_in_fallback(&mut self, now: f64, last_picture_at: Option<f64>) -> Decision {
        let held = now - self.fell_back_at >= MIN_FALLBACK_HOLD;
        if held && self.primary_pictures >= PRIMARY_PICTURES_FOR_RETURN {
            self.is_fallback = false;
            self.primary_pictures = 0;
            self.last_request_at = Some(now);
            return Decision::UsePrimaryTransport;
        }
        // The host may decline a request, so one that produced no picture is repeated rather than
        // assumed to have worked.
        let asked_at = self.last_request_at.unwrap_or(0.0);
        let pictured_since_asking = last_picture_at.is_some_and(|picture| picture > asked_at);
        if !pictured_since_asking && now - asked_at >= REQUEST_REPEAT_INTERVAL {
            self.last_request_at = Some(now);
            return Decision::UseControlChannel;
        }
        Decision::None
    }

    fn advance_on_primary(
        &mut self,
        now: f64,
        last_picture_at: Option<f64>,
        last_control_reply_at: Option<f64>,
    ) -> Decision {
        let Some(last_picture_at) = last_picture_at else {
            return Decision::None;
        };
        if now - last_picture_at < SILENCE_BEFORE_FALLBACK {
            return Decision::None;
        }
        // The control channel is about to carry the whole picture, so it must be demonstrably alive.
        let control_alive = last_control_reply_at
            .is_some_and(|reply| now - reply <= CONTROL_HEALTH_WINDOW);
        if !control_alive {
            return Decision::None;
        }
        if self.last_request_at.is_some_and(|asked| now - asked < REQUEST_REPEAT_INTERVAL) {
            return Decision::None;
        }
        self.last_request_at = Some(now);
        self.fell_back_at = now;
        self.primary_pictures = 0;
        self.is_fallback = true;
        Decision::UseControlChannel
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostAnswer {
    Serve,
    Decline,
}

/// Declines a fallback request while nothing has been produced: a still screen and a blocked path
/// look identical from the host, so producing nothing is not evidence the path is broken.
#[derive(Debug, Default, Clone, Copy)]
pub struct HostFallbackGate;

impl HostFallbackGate {
    pub fn decide(&self, now: f64, last_frame_produced_at: Option<f64>) -> HostAnswer {
        match last_frame_produced_at {
            Some(produced) if now - produced <= HOST_PRODUCTION_WINDOW => HostAnswer::Serve,
            _ => HostAnswer::Decline,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_waits_for_three_seconds_of_silence() {
        let cases = [
            (Some(0.0), Some(2.5), 2.99, Decision::None),
            (Some(0.0), Some(2.5), 3.0, Decision::UseControlChannel),
            (None, Some(3.0), 3.0, Decision::None),
            (Some(0.0), None, 3.0, Decision::None),
            (Some(0.5), Some(0.5), 6.0, Decision::None),
        ];
        for (picture, reply, now, expected) in cases {
            let mut policy = ClientFallbackPolicy::new();
            assert_eq!(policy.advance(now, picture, reply, true), expected, "now {now}");
        }
    }

    #[test]
    fn fallback_needs_a_control_reply_within_five_seconds() {
        let mut policy = ClientFallbackPolicy::new();
        assert_eq!(policy.advance(9.0, Some(0.0), Some(3.9), true), Decision::None);
        assert_eq!(policy.advance(9.0, Some(0.0), Some(4.0), true), Decision::UseControlChannel);
    }

    #[test]
    fn the_request_repeats_every_five_seconds_until_a_picture_arrives() {
        let mut policy = ClientFallbackPolicy::new();
        assert_eq!(policy.advance(3.0, Some(0.0), Some(3.0), true), Decision::UseControlChannel);
        assert_eq!(policy.advance(7.9, Some(0.0), Some(7.9), true), Decision::None);
        assert_eq!(policy.advance(8.0, Some(0.0), Some(8.0), true), Decision::UseControlChannel);
        assert_eq!(policy.advance(8.5, Some(8.5), Some(8.5), true), Decision::None);
        assert_eq!(policy.advance(13.0, Some(8.5), Some(13.0), true), Decision::None);
        assert!(policy.is_fallback());
    }

    #[test]
    fn return_needs_both_the_hold_and_two_primary_pictures() {
        let mut policy = ClientFallbackPolicy::new();
        policy.advance(3.0, Some(0.0), Some(3.0), true);
        policy.note_primary_picture();
        assert_eq!(policy.advance(8.0, Some(4.0), Some(8.0), true), Decision::None);
        policy.note_primary_picture();
        assert_eq!(policy.advance(7.0, Some(4.0), Some(7.0), true), Decision::None);
        assert_eq!(policy.advance(8.0, Some(4.0), Some(8.0), true), Decision::UsePrimaryTransport);
        assert!(!policy.is_fallback());
    }

    #[test]
    fn two_pictures_before_the_hold_do_not_return() {
        let mut policy = ClientFallbackPolicy::new();
        policy.advance(3.0, Some(0.0), Some(3.0), true);
        policy.note_primary_picture();
        policy.note_primary_picture();
        assert_eq!(policy.advance(4.5, Some(4.0), Some(4.5), true), Decision::None);
        assert!(policy.is_fallback());
    }

    #[test]
    fn nothing_happens_when_the_policy_does_not_apply() {
        let mut policy = ClientFallbackPolicy::new();
        assert_eq!(policy.advance(10.0, Some(0.0), Some(10.0), false), Decision::None);
        assert!(!policy.is_fallback());
        policy.advance(3.0, Some(0.0), Some(3.0), true);
        assert_eq!(policy.advance(20.0, Some(0.0), Some(20.0), false), Decision::None);
        assert!(policy.is_fallback());
    }

    #[test]
    fn reset_leaves_fallback_and_forgets_the_last_request() {
        let mut policy = ClientFallbackPolicy::new();
        policy.advance(3.0, Some(0.0), Some(3.0), true);
        policy.reset();
        assert!(!policy.is_fallback());
        assert_eq!(policy.advance(3.5, Some(0.0), Some(3.5), true), Decision::UseControlChannel);
    }

    #[test]
    fn host_declines_when_nothing_was_produced_recently() {
        let gate = HostFallbackGate;
        let cases = [
            (10.0, Some(5.0), HostAnswer::Serve),
            (10.5, Some(5.0), HostAnswer::Decline),
            (1.0, Some(1.0), HostAnswer::Serve),
            (1.0, None, HostAnswer::Decline),
        ];
        for (now, produced, expected) in cases {
            assert_eq!(gate.decide(now, produced), expected, "now {now}");
        }
    }
}
