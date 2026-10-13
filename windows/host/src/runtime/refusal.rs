//! Telling a phone that the host cannot do what it asked, so the control it used does not appear to hang. A refusal is a
//! notice that lapses by itself: an `error` frame would end an iPhone session, and a standing notice would stay on screen.

use peering_core::session::dispatch::IgnoreReason;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::NoticePayload;

use crate::strings;

/// How long a refusal stays on the phone before it clears.
pub const REFUSAL_SECONDS: f64 = 6.0;
const WARNING_SYMBOL: &str = "exclamationmark.triangle.fill";
/// The code the iPhone words itself for a privacy mode that could not darken the displays.
const PRIVACY_FAILED_CODE: &str = "privacyModeFailed";
/// The code the iPhone words itself for a display that is gone.
const DISPLAY_GONE_CODE: &str = "displayDisconnected";

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

/// What to tell the phone for a command that was recognised and not carried out, or `None` for one a phone only sends to a
/// host that declared it (switching privacy mode off needs no word either).
pub fn notice_for(reason: IgnoreReason) -> Option<NoticePayload> {
    match reason {
        IgnoreReason::PrivacyMode { enabled: true } => Some(warning(strings::PRIVACY_MODE_UNAVAILABLE, Some(PRIVACY_FAILED_CODE))),
        IgnoreReason::SpaceSwitch => Some(warning(strings::DESKTOPS_UNAVAILABLE, None)),
        IgnoreReason::WindowAction => Some(warning(strings::WINDOW_ACTIONS_UNAVAILABLE, None)),
        IgnoreReason::Launch => Some(warning(strings::LAUNCH_UNAVAILABLE, None)),
        IgnoreReason::MosaicSource => Some(warning(strings::MOSAIC_UNAVAILABLE, None)),
        IgnoreReason::PrivacyMode { enabled: false }
        | IgnoreReason::ObserveMode
        | IgnoreReason::VirtualDisplay
        | IgnoreReason::NotSupportedHere => None,
    }
}

/// A capture source that could not be used. The code is one the phone has words for, so it can say what to do next.
pub fn source_unavailable(reason: &str) -> NoticePayload {
    warning(reason, Some(DISPLAY_GONE_CODE))
}

/// The answer to a web preview request, which this host does not serve: the request's own id with `notAllowed`, so the page
/// stops waiting. A cancel and anything unreadable get none.
pub fn preview_refusal(payload: &[u8]) -> Option<Frame> {
    let request: serde_json::Value = serde_json::from_slice(payload).ok()?;
    let id = request.get("fetch")?.get("_0")?.get("id")?.as_u64()?;
    let failure = serde_json::json!({ "failure": { "id": id, "reason": "notAllowed" } });
    // A json! object of numbers and strings.
    Some(Frame::new(MessageKind::PreviewEvent, serde_json::to_vec(&failure).expect("a preview failure always serialises")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn privacy_mode_asked_for_is_refused_with_the_code_the_iphone_words() {
        let notice = notice_for(IgnoreReason::PrivacyMode { enabled: true }).expect("a notice");
        assert_eq!(notice.code.as_deref(), Some("privacyModeFailed"));
        assert!(notice.message.is_some());
    }

    #[test]
    fn switching_privacy_mode_off_is_not_refused() {
        assert_eq!(notice_for(IgnoreReason::PrivacyMode { enabled: false }), None);
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

    #[test]
    fn a_preview_fetch_is_answered_with_its_own_id() {
        let request = br#"{"fetch":{"_0":{"id":7,"port":3000,"method":"GET","target":"/","headers":[]}}}"#;
        let frame = preview_refusal(request).expect("a refusal");
        assert_eq!(frame.kind, MessageKind::PreviewEvent);
        let value: serde_json::Value = serde_json::from_slice(&frame.payload).unwrap();
        assert_eq!(value, serde_json::json!({ "failure": { "id": 7, "reason": "notAllowed" } }));
    }

    #[test]
    fn a_cancel_or_garbage_gets_no_answer() {
        assert_eq!(preview_refusal(br#"{"cancel":{"id":7}}"#), None);
        assert_eq!(preview_refusal(b"nonsense"), None);
    }
}
