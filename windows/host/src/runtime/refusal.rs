//! Telling a phone that the host cannot do what it asked, so the control it used does not appear to hang. A refusal is a
//! notice that lapses by itself: an `error` frame would end an iPhone session, and a standing notice would stay on screen.

use peering_core::ports::curtain::PrivacyOutcome;
use peering_core::session::dispatch::IgnoreReason;
use peering_wire::handshake::NoticePayload;

use crate::strings;

/// How long a refusal stays on the phone before it clears.
pub const REFUSAL_SECONDS: f64 = 6.0;
const WARNING_SYMBOL: &str = "exclamationmark.triangle.fill";
/// The codes the iPhone words itself for a privacy mode that could not darken the displays, or left some uncovered.
const PRIVACY_FAILED_CODE: &str = "privacy-mode-failed";
const PRIVACY_UNCOVERED_CODE: &str = "privacy-mode-uncovered";
/// The code the iPhone words itself for a display that is gone.
const DISPLAY_GONE_CODE: &str = "display-disconnected";

/// A refusal in force until `expires_at`.
#[derive(Debug, Clone, PartialEq)]
pub struct Refusal {
    pub notice: NoticePayload,
    pub expires_at: f64,
}

impl Refusal {
    pub fn until(notice: NoticePayload, now: f64) -> Self {
        Self { notice, expires_at: now + REFUSAL_SECONDS }
    }

    pub fn in_force(&self, now: f64) -> bool {
        now < self.expires_at
    }
}

pub fn notice_for_text(message: &str) -> NoticePayload {
    warning(message, None)
}

fn warning(message: &str, code: Option<&str>) -> NoticePayload {
    NoticePayload {
        message: Some(message.to_owned()),
        symbol: Some(WARNING_SYMBOL.to_owned()),
        locked_display_id: None,
        code: code.map(str::to_owned),
    }
}

/// What to tell the phone after switching privacy mode, or `None` when it went as asked.
pub fn privacy_notice(outcome: PrivacyOutcome) -> Option<NoticePayload> {
    match outcome {
        PrivacyOutcome::Quiet => None,
        PrivacyOutcome::Failed => Some(warning(strings::PRIVACY_MODE_FAILED, Some(PRIVACY_FAILED_CODE))),
        PrivacyOutcome::Uncovered(count) => {
            Some(warning(&strings::privacy_mode_uncovered(count), Some(PRIVACY_UNCOVERED_CODE)))
        }
    }
}

/// What to tell the phone for a command that was recognised and not carried out, or `None` for one a phone only sends to a
/// host that declared it (switching privacy mode off needs no word either).
pub fn notice_for(reason: IgnoreReason) -> Option<NoticePayload> {
    match reason {
        IgnoreReason::SpaceSwitch => Some(warning(strings::DESKTOPS_UNAVAILABLE, None)),
        IgnoreReason::WindowAction => Some(warning(strings::WINDOW_ACTIONS_UNAVAILABLE, None)),
        IgnoreReason::Launch => Some(warning(strings::LAUNCH_UNAVAILABLE, None)),
        IgnoreReason::MosaicSource => Some(warning(strings::MOSAIC_UNAVAILABLE, None)),
        IgnoreReason::ObserveMode
        | IgnoreReason::VirtualDisplay
        | IgnoreReason::NotSupportedHere => None,
    }
}

/// A capture source that could not be used. The code is one the phone has words for, so it can say what to do next.
pub fn source_unavailable(reason: &str) -> NoticePayload {
    warning(reason, Some(DISPLAY_GONE_CODE))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn privacy_mode_that_covered_nothing_is_worded_by_the_iphone_code() {
        let notice = privacy_notice(PrivacyOutcome::Failed).expect("a notice");
        assert_eq!(notice.code.as_deref(), Some("privacy-mode-failed"));
        assert_eq!(privacy_notice(PrivacyOutcome::Quiet), None);
        let uncovered = privacy_notice(PrivacyOutcome::Uncovered(2)).expect("a notice");
        assert_eq!(uncovered.code.as_deref(), Some("privacy-mode-uncovered"));
    }

    #[test]
    fn commands_a_phone_only_sends_to_a_host_that_declared_them_say_nothing() {
        assert_eq!(notice_for(IgnoreReason::VirtualDisplay), None);
        assert_eq!(notice_for(IgnoreReason::NotSupportedHere), None);
        assert_eq!(notice_for(IgnoreReason::ObserveMode), None);
    }

    #[test]
    fn spaces_windows_launches_and_mosaics_are_refused_in_words() {
        for reason in [IgnoreReason::SpaceSwitch, IgnoreReason::WindowAction, IgnoreReason::Launch, IgnoreReason::MosaicSource] {
            assert!(notice_for(reason).is_some_and(|notice| notice.message.is_some()), "{reason:?}");
        }
    }

    #[test]
    fn a_refusal_lapses_after_its_time() {
        let refusal = Refusal::until(source_unavailable("gone"), 10.0);
        assert!(refusal.in_force(15.9));
        assert!(!refusal.in_force(16.0));
    }
}
