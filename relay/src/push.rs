//! Which push service a device token belongs to.
//!
//! The Mac hex-encodes whatever bytes a phone registered and never looks inside them, so the
//! kind has to travel in the bytes: an Android client registers the ASCII text `fcm:` followed by
//! its Firebase registration token. Everything else is an APNs token, as before.

use crate::protocol::hex_bytes;

const FCM_PREFIX: &[u8] = b"fcm:";

/// Registration tokens are well under 512 bytes; the cap keeps a hostile value from being decoded at length.
const MAX_TOKEN_BYTES: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushTarget {
    Apns(String),
    /// The Firebase registration token, without the prefix.
    Fcm(String),
}

pub fn target_for(device_token_hex: &str) -> PushTarget {
    let Some(bytes) = hex_bytes(device_token_hex, MAX_TOKEN_BYTES) else {
        return PushTarget::Apns(device_token_hex.to_owned());
    };
    match bytes.strip_prefix(FCM_PREFIX).map(std::str::from_utf8) {
        Some(Ok(token)) if !token.is_empty() && token.chars().all(is_token_char) => PushTarget::Fcm(token.to_owned()),
        _ => PushTarget::Apns(device_token_hex.to_owned()),
    }
}

/// FCM tokens are URL-safe text with a colon between two parts.
fn is_token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex_of(text: &[u8]) -> String {
        text.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn a_32_byte_token_is_apns() {
        let token = "ab".repeat(32);
        assert_eq!(target_for(&token), PushTarget::Apns(token));
    }

    #[test]
    fn the_prefix_marks_fcm_and_is_removed() {
        let token = hex_of(b"fcm:abc123:APA91b-_x");
        assert_eq!(target_for(&token), PushTarget::Fcm("abc123:APA91b-_x".into()));
    }

    #[test]
    fn a_prefix_with_nothing_after_it_is_not_fcm() {
        let token = hex_of(b"fcm:");
        assert_eq!(target_for(&token), PushTarget::Apns(token));
    }

    #[test]
    fn garbage_and_odd_length_hex_stay_apns() {
        assert_eq!(target_for("not hex"), PushTarget::Apns("not hex".into()));
        assert_eq!(target_for("abc"), PushTarget::Apns("abc".into()));
    }

    #[test]
    fn text_outside_the_token_alphabet_is_not_fcm() {
        let token = hex_of(b"fcm:bad token");
        assert_eq!(target_for(&token), PushTarget::Apns(token));
    }

    #[test]
    fn an_oversized_value_is_not_decoded() {
        let token = "61".repeat(600);
        assert_eq!(target_for(&token), PushTarget::Apns(token));
    }
}
