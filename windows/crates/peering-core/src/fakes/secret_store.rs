use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use super::lock;
use crate::ports::secret_store::{SecretStore, StoreError};

/// A secret store in a map. `set_fail_writes(true)` makes every `write` fail and keep the old value;
/// `set_fail_reads(true)` makes every `read` return an error while the values stay in place.
#[derive(Debug, Default)]
pub struct InMemorySecretStore {
    values: Mutex<HashMap<String, Vec<u8>>>,
    fail_writes: AtomicBool,
    fail_reads: AtomicBool,
}

impl InMemorySecretStore {
    pub fn set_fail_writes(&self, fail: bool) {
        self.fail_writes.store(fail, Ordering::SeqCst);
    }

    pub fn set_fail_reads(&self, fail: bool) {
        self.fail_reads.store(fail, Ordering::SeqCst);
    }
}

impl SecretStore for InMemorySecretStore {
    fn read(&self, name: &str) -> Result<Option<Vec<u8>>, StoreError> {
        if self.fail_reads.load(Ordering::SeqCst) {
            return Err(StoreError);
        }
        Ok(lock(&self.values).get(name).cloned())
    }

    fn write(&self, name: &str, value: &[u8]) -> bool {
        if self.fail_writes.load(Ordering::SeqCst) {
            return false;
        }
        lock(&self.values).insert(name.to_owned(), value.to_vec());
        true
    }

    fn remove(&self, name: &str) -> bool {
        lock(&self.values).remove(name);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn written_value_reads_back_and_remove_clears_it() {
        let store = InMemorySecretStore::default();
        assert!(store.write("key", b"abc"));
        assert_eq!(store.read("key"), Ok(Some(b"abc".to_vec())));
        assert!(store.remove("key"));
        assert_eq!(store.read("key"), Ok(None));
    }

    #[test]
    fn failed_write_keeps_the_previous_value() {
        let store = InMemorySecretStore::default();
        assert!(store.write("pin", b"old"));
        store.set_fail_writes(true);
        assert!(!store.write("pin", b"new"));
        assert_eq!(store.read("pin"), Ok(Some(b"old".to_vec())));
    }

    #[test]
    fn a_failed_read_is_an_error_and_keeps_the_value() {
        let store = InMemorySecretStore::default();
        assert!(store.write("key", b"abc"));
        store.set_fail_reads(true);
        assert_eq!(store.read("key"), Err(StoreError));
        store.set_fail_reads(false);
        assert_eq!(store.read("key"), Ok(Some(b"abc".to_vec())));
    }
}
