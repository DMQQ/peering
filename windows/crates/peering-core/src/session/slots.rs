//! Choosing among the control sessions a host holds when more than one belongs to the same phone.

/// The newest session whose certificate key is `key`. A phone that reconnects leaves its old session open until the
/// old socket times out, and the video connection belongs to the new one. Session ids only grow.
pub fn newest_session_for_key<'a>(sessions: impl IntoIterator<Item = (u64, Option<&'a [u8]>)>, key: &[u8]) -> Option<u64> {
    sessions.into_iter().filter(|(_, session_key)| *session_key == Some(key)).map(|(id, _)| id).max()
}

/// True when a session other than `except` belongs to `client_id`, so the client's video and input must stay.
pub fn client_has_other_session<'a>(sessions: impl IntoIterator<Item = (u64, &'a str)>, client_id: &str, except: u64) -> bool {
    sessions.into_iter().any(|(id, other)| id != except && other == client_id)
}

/// Every session that belongs to `client_id`, for ending them all when the device is removed.
pub fn sessions_of_client<'a>(sessions: impl IntoIterator<Item = (u64, &'a str)>, client_id: &str) -> Vec<u64> {
    sessions.into_iter().filter(|(_, other)| *other == client_id).map(|(id, _)| id).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_newest_session_with_the_key_is_chosen() {
        let key = [1u8, 2];
        let other = [9u8];
        let sessions = vec![(7, Some(&key[..])), (3, Some(&key[..])), (9, Some(&other[..])), (11, None)];
        assert_eq!(newest_session_for_key(sessions, &key), Some(7));
    }

    #[test]
    fn no_session_with_the_key_gives_none() {
        let other = [9u8];
        assert_eq!(newest_session_for_key(vec![(1, Some(&other[..]))], &[1]), None);
    }

    #[test]
    fn a_sibling_session_of_the_same_client_is_found_but_not_itself() {
        let sessions = vec![(1, "phone"), (2, "phone"), (3, "tablet")];
        assert!(client_has_other_session(sessions.clone(), "phone", 1));
        assert!(!client_has_other_session(sessions, "tablet", 3));
    }

    #[test]
    fn every_session_of_a_removed_client_is_listed() {
        let sessions = vec![(1, "phone"), (2, "tablet"), (3, "phone")];
        let mut found = sessions_of_client(sessions, "phone");
        found.sort_unstable();
        assert_eq!(found, vec![1, 3]);
    }
}
