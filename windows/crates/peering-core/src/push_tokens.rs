//! The push tokens phones register with this Mac, kept across a restart of it. Mirrors `apple/MacCastHost/Terminal/PushTokenStore.swift`.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use crate::ports::secret_store::{SecretStore, StoreError};

const STORAGE_NAME: &str = "pushTokens";

/// Tokens by client id, as lowercase hex of the bytes the phone sent.
///
/// A change is written before it is applied in memory, so a failed write leaves both unchanged. `change_order`
/// is held across the write so two changes are computed from the state the previous one committed; `tokens` is
/// only held for the copy in and out, never across the write.
pub struct PushTokenStore<S: SecretStore> {
    secrets: S,
    tokens: Mutex<BTreeMap<String, String>>,
    change_order: Mutex<()>,
}

impl<S: SecretStore> PushTokenStore<S> {
    /// Loads the saved tokens. A value that does not decode as a map of strings is treated as none saved; a read
    /// that fails is an error, because continuing would overwrite the saved tokens on the next change.
    pub fn open(secrets: S) -> Result<Self, StoreError> {
        let tokens = secrets
            .read(STORAGE_NAME)?
            .and_then(|bytes| serde_json::from_slice::<BTreeMap<String, String>>(&bytes).ok())
            .unwrap_or_default();
        Ok(Self {
            secrets,
            tokens: Mutex::new(tokens),
            change_order: Mutex::new(()),
        })
    }

    /// Stores the token for a client, or forgets it when `bytes` is empty. Returns false, changing nothing,
    /// when the change could not be saved.
    #[must_use]
    pub fn register(&self, client_id: &str, bytes: &[u8]) -> bool {
        if bytes.is_empty() {
            return self.forget(client_id);
        }
        self.change(|tokens| {
            tokens.insert(client_id.to_owned(), hex_lowercase(bytes));
        })
    }

    #[must_use]
    pub fn forget(&self, client_id: &str) -> bool {
        self.change(|tokens| {
            tokens.remove(client_id);
        })
    }

    #[must_use]
    pub fn forget_all(&self) -> bool {
        self.change(BTreeMap::clear)
    }

    pub fn token_for(&self, client_id: &str) -> Option<String> {
        lock(&self.tokens).get(client_id).cloned()
    }

    pub fn all(&self) -> BTreeMap<String, String> {
        lock(&self.tokens).clone()
    }

    fn change(&self, edit: impl FnOnce(&mut BTreeMap<String, String>)) -> bool {
        let _order = lock(&self.change_order);
        let mut updated = lock(&self.tokens).clone();
        edit(&mut updated);
        let Ok(encoded) = serde_json::to_vec(&updated) else {
            return false;
        };
        if !self.secrets.write(STORAGE_NAME, &encoded) {
            return false;
        }
        *lock(&self.tokens) = updated;
        true
    }
}

fn hex_lowercase(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::fakes::secret_store::InMemorySecretStore;

    /// Lets a test reopen the store over the same saved values, as a restart of the Mac does.
    struct SharedSecrets(Arc<InMemorySecretStore>);

    impl SecretStore for SharedSecrets {
        fn read(&self, name: &str) -> Result<Option<Vec<u8>>, StoreError> {
            self.0.read(name)
        }
        fn write(&self, name: &str, value: &[u8]) -> bool {
            self.0.write(name, value)
        }
        fn remove(&self, name: &str) -> bool {
            self.0.remove(name)
        }
    }

    fn empty_store() -> (Arc<InMemorySecretStore>, PushTokenStore<SharedSecrets>) {
        let secrets = Arc::new(InMemorySecretStore::default());
        let store = PushTokenStore::open(SharedSecrets(Arc::clone(&secrets))).expect("store opens");
        (secrets, store)
    }

    fn decode_hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&text[index..index + 2], 16).expect("hex digits"))
            .collect()
    }

    #[test]
    fn registered_bytes_are_kept_as_lowercase_hex() {
        let (_, store) = empty_store();
        assert!(store.register("phone-a", &[0x0a, 0xff, 0x00]));
        assert_eq!(store.token_for("phone-a").as_deref(), Some("0aff00"));
    }

    #[test]
    fn registering_empty_bytes_forgets_the_client() {
        let (_, store) = empty_store();
        assert!(store.register("phone-a", b"token"));
        assert!(store.register("phone-a", &[]));
        assert_eq!(store.token_for("phone-a"), None);
    }

    #[test]
    fn a_later_registration_replaces_the_earlier_token() {
        let (_, store) = empty_store();
        assert!(store.register("phone-a", &[1]));
        assert!(store.register("phone-a", &[2]));
        assert_eq!(store.token_for("phone-a").as_deref(), Some("02"));
    }

    #[test]
    fn an_android_token_sent_as_fcm_prefixed_bytes_round_trips_to_the_same_text() {
        let (_, store) = empty_store();
        let sent = b"fcm:dGVzdC10b2tlbg";
        assert!(store.register("android-phone", sent));
        let stored = store.token_for("android-phone").expect("token is stored");
        assert_eq!(decode_hex(&stored), sent);
    }

    #[test]
    fn forget_all_clears_every_client() {
        let (_, store) = empty_store();
        assert!(store.register("phone-a", &[1]));
        assert!(store.register("phone-b", &[2]));
        assert!(store.forget_all());
        assert!(store.all().is_empty());
    }

    #[test]
    fn tokens_survive_reopening_the_store() {
        let (secrets, store) = empty_store();
        assert!(store.register("phone-a", &[0xab]));
        drop(store);
        let reopened = PushTokenStore::open(SharedSecrets(secrets)).expect("store opens");
        assert_eq!(reopened.token_for("phone-a").as_deref(), Some("ab"));
    }

    #[test]
    fn a_failed_write_leaves_the_memory_unchanged() {
        let (secrets, store) = empty_store();
        assert!(store.register("phone-a", &[1]));
        secrets.set_fail_writes(true);
        assert!(!store.register("phone-a", &[2]));
        assert!(!store.register("phone-b", &[3]));
        assert!(!store.forget("phone-a"));
        assert!(!store.forget_all());
        assert_eq!(store.all().len(), 1);
        assert_eq!(store.token_for("phone-a").as_deref(), Some("01"));
    }

    #[test]
    fn a_failed_write_is_not_visible_after_a_restart() {
        let (secrets, store) = empty_store();
        secrets.set_fail_writes(true);
        assert!(!store.register("phone-a", &[1]));
        drop(store);
        let reopened = PushTokenStore::open(SharedSecrets(secrets)).expect("store opens");
        assert!(reopened.all().is_empty());
    }

    #[test]
    fn a_saved_value_that_is_not_a_token_map_is_read_as_none() {
        let secrets = Arc::new(InMemorySecretStore::default());
        assert!(secrets.write(STORAGE_NAME, b"not json"));
        let store = PushTokenStore::open(SharedSecrets(secrets)).expect("store opens");
        assert!(store.all().is_empty());
    }

    #[test]
    fn a_failed_read_refuses_to_open_so_saved_tokens_are_not_overwritten() {
        let secrets = Arc::new(InMemorySecretStore::default());
        assert!(secrets.write(STORAGE_NAME, br#"{"phone-a":"0a"}"#));
        secrets.set_fail_reads(true);
        assert!(PushTokenStore::open(SharedSecrets(Arc::clone(&secrets))).is_err());
        secrets.set_fail_reads(false);
        let store = PushTokenStore::open(SharedSecrets(secrets)).expect("store opens");
        assert_eq!(store.token_for("phone-a").as_deref(), Some("0a"));
    }
}
