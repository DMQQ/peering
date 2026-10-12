//! Whether capture can see the screen. The decision in `from_signals` and the notice wording are pure; the OS reads
//! live in `session_state/sys.rs`.

use peering_wire::handshake::NoticePayload;

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::{input_desktop_is_default, session_locked};

const LOCKED_MESSAGE: &str = "This PC is locked";
const SECURE_DESKTOP_MESSAGE: &str = "A Windows security prompt is on screen";
const LOCKED_SYMBOL: &str = "lock.fill";
const SECURE_DESKTOP_SYMBOL: &str = "exclamationmark.shield.fill";
const WTS_SESSION_LOCKED: i32 = 0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Normal,
    Locked,
    SecureDesktop,
    /// Capture is failing for no reason the signals explain, such as a display mode change.
    Unknown,
}

/// The lock screen wins over the secure desktop it sits on. Lost frames on an otherwise ordinary desktop are reported
/// as Unknown rather than given a cause.
pub fn from_signals(input_desktop_is_default: bool, session_locked: bool, access_lost_count: u32) -> SessionState {
    if session_locked {
        SessionState::Locked
    } else if !input_desktop_is_default {
        SessionState::SecureDesktop
    } else if access_lost_count > 0 {
        SessionState::Unknown
    } else {
        SessionState::Normal
    }
}

/// The notice to send for `state`, or None when there is nothing to show. A client that is still showing a notice
/// must be sent a payload with no message to clear it.
pub fn notice_for(state: SessionState) -> Option<NoticePayload> {
    let (message, symbol) = match state {
        SessionState::Locked => (LOCKED_MESSAGE, LOCKED_SYMBOL),
        SessionState::SecureDesktop => (SECURE_DESKTOP_MESSAGE, SECURE_DESKTOP_SYMBOL),
        SessionState::Normal | SessionState::Unknown => return None,
    };
    Some(NoticePayload {
        message: Some(message.to_string()),
        symbol: Some(symbol.to_string()),
        locked_display_id: None,
    })
}

/// Reads the live signals and classifies them. `access_lost_count` comes from the capture.
#[cfg(windows)]
pub fn current_state(access_lost_count: u32) -> SessionState {
    from_signals(input_desktop_is_default(), session_locked(), access_lost_count)
}

/// WTS reports lock state in SessionFlags: 0 is locked, 1 is unlocked, and anything else means it could not tell.
pub fn session_flags_say_locked(session_flags: i32) -> bool {
    session_flags == WTS_SESSION_LOCKED
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ordinary_desktop_without_losses_is_normal() {
        assert_eq!(from_signals(true, false, 0), SessionState::Normal);
    }

    #[test]
    fn a_locked_session_is_locked_even_on_the_secure_desktop() {
        assert_eq!(from_signals(false, true, 3), SessionState::Locked);
        assert_eq!(from_signals(true, true, 0), SessionState::Locked);
    }

    #[test]
    fn a_non_default_input_desktop_is_the_secure_desktop() {
        assert_eq!(from_signals(false, false, 0), SessionState::SecureDesktop);
        assert_eq!(from_signals(false, false, 5), SessionState::SecureDesktop);
    }

    #[test]
    fn lost_frames_with_no_explanation_are_unknown() {
        assert_eq!(from_signals(true, false, 1), SessionState::Unknown);
    }

    #[test]
    fn every_combination_of_signals_has_a_defined_state() {
        let cases = [
            (true, false, 0, SessionState::Normal),
            (true, false, 2, SessionState::Unknown),
            (true, true, 0, SessionState::Locked),
            (true, true, 2, SessionState::Locked),
            (false, false, 0, SessionState::SecureDesktop),
            (false, false, 2, SessionState::SecureDesktop),
            (false, true, 0, SessionState::Locked),
            (false, true, 2, SessionState::Locked),
        ];
        for (default_desktop, locked, losses, expected) in cases {
            assert_eq!(from_signals(default_desktop, locked, losses), expected);
        }
    }

    #[test]
    fn the_locked_notice_says_the_pc_is_locked() {
        let notice = notice_for(SessionState::Locked).expect("a locked session has a notice");
        assert_eq!(notice.message.as_deref(), Some("This PC is locked"));
        assert_eq!(notice.symbol.as_deref(), Some("lock.fill"));
        assert_eq!(notice.locked_display_id, None);
    }

    #[test]
    fn the_secure_desktop_notice_names_the_security_prompt() {
        let notice = notice_for(SessionState::SecureDesktop).expect("the secure desktop has a notice");
        assert_eq!(notice.message.as_deref(), Some("A Windows security prompt is on screen"));
    }

    #[test]
    fn normal_and_unknown_have_no_notice() {
        assert_eq!(notice_for(SessionState::Normal), None);
        assert_eq!(notice_for(SessionState::Unknown), None);
    }

    #[test]
    fn only_session_flags_zero_mean_locked() {
        assert!(session_flags_say_locked(0));
        assert!(!session_flags_say_locked(1));
        assert!(!session_flags_say_locked(-1));
    }
}
