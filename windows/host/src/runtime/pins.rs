//! The paired devices, kept in the secret store as one JSON list. A failed write leaves the previous list in memory
//! and on disk, so a pairing that could not be saved is reported as not saved. A list that is there but does not decode
//! is never read as empty: the bytes are copied aside, the stored list is left untouched, and every change is refused
//! until the person deals with it.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_core::ports::secret_store::{SecretStore, StoreError};
use peering_core::session::deps::{PairedDevice, PinStore};
use serde::{Deserialize, Serialize};

const STORAGE_NAME: &str = "pairedDevices";
/// Secret names cannot hold a dot, so the kept copy is `pairedDevices-bad` rather than `pairedDevices.bad`.
const KEPT_COPY_NAME: &str = "pairedDevices-bad";

#[derive(Serialize, Deserialize)]
struct StoredDevice {
    id: String,
    name: String,
    public_key: String,
    last_seen_unix: u64,
}

pub struct SecretPins {
    secrets: Arc<dyn SecretStore + Send + Sync>,
    devices: Mutex<Vec<PairedDevice>>,
    unreadable: Option<Unreadable>,
}

/// What happened to a stored list that did not decode.
#[derive(Clone, Copy)]
struct Unreadable {
    copy_kept: bool,
}

impl SecretPins {
    /// A read that fails is an error: an empty list here would let the next pairing overwrite every saved device.
    pub fn open(secrets: Arc<dyn SecretStore + Send + Sync>) -> Result<Self, StoreError> {
        let (devices, unreadable) = match secrets.read(STORAGE_NAME)? {
            None => (Vec::new(), None),
            Some(bytes) => match decode(&bytes) {
                Some(devices) => (devices, None),
                None => (Vec::new(), Some(Unreadable { copy_kept: secrets.write(KEPT_COPY_NAME, &bytes) })),
            },
        };
        Ok(Self { secrets, devices: Mutex::new(devices), unreadable })
    }

    /// The sentence for the window when the stored list could not be read, else `None`.
    pub fn load_problem(&self) -> Option<String> {
        self.unreadable.map(|unreadable| crate::strings::paired_list_unreadable(unreadable.copy_kept))
    }

    fn locked(&self) -> MutexGuard<'_, Vec<PairedDevice>> {
        self.devices.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn save(&self, devices: &[PairedDevice]) -> bool {
        let stored: Vec<StoredDevice> = devices.iter().map(stored_from).collect();
        match serde_json::to_vec(&stored) {
            Ok(bytes) => self.secrets.write(STORAGE_NAME, &bytes),
            Err(_) => false,
        }
    }
}

/// `None` when the bytes are not a list of devices. One entry that does not decode makes the whole list unreadable:
/// dropping it quietly would let the next save erase it.
fn decode(bytes: &[u8]) -> Option<Vec<PairedDevice>> {
    let stored: Vec<StoredDevice> = serde_json::from_slice(bytes).ok()?;
    stored
        .into_iter()
        .map(|device| {
            Some(PairedDevice {
                id: device.id,
                name: device.name,
                public_key: hex::decode(device.public_key).ok()?,
                last_seen_unix: device.last_seen_unix,
            })
        })
        .collect()
}

fn stored_from(device: &PairedDevice) -> StoredDevice {
    StoredDevice {
        id: device.id.clone(),
        name: device.name.clone(),
        public_key: hex::encode(&device.public_key),
        last_seen_unix: device.last_seen_unix,
    }
}

impl PinStore for SecretPins {
    fn pin_for(&self, client_id: &str) -> Option<Vec<u8>> {
        self.locked().iter().find(|device| device.id == client_id).map(|device| device.public_key.clone())
    }

    fn record(&self, device: &PairedDevice) -> bool {
        if self.unreadable.is_some() {
            return false;
        }
        let mut devices = self.locked();
        let mut next = devices.clone();
        match next.iter_mut().find(|known| known.id == device.id) {
            Some(known) => *known = device.clone(),
            None => next.push(device.clone()),
        }
        if !self.save(&next) {
            return false;
        }
        *devices = next;
        true
    }

    fn mark_seen(&self, client_id: &str, unix_seconds: u64) {
        if self.unreadable.is_some() {
            return;
        }
        let mut devices = self.locked();
        let mut next = devices.clone();
        if let Some(known) = next.iter_mut().find(|known| known.id == client_id) {
            known.last_seen_unix = unix_seconds;
        }
        // last_seen is informational: a failed write keeps the new time in memory until the next successful save.
        let _saved = self.save(&next);
        *devices = next;
    }

    fn devices(&self) -> Vec<PairedDevice> {
        self.locked().clone()
    }

    fn revoke(&self, client_id: &str) -> bool {
        if self.unreadable.is_some() {
            return false;
        }
        let mut devices = self.locked();
        let next: Vec<PairedDevice> = devices.iter().filter(|known| known.id != client_id).cloned().collect();
        if next.len() == devices.len() {
            return true;
        }
        if !self.save(&next) {
            return false;
        }
        *devices = next;
        true
    }
}

#[cfg(test)]
mod tests {
    use peering_core::fakes::secret_store::InMemorySecretStore;

    use super::*;

    fn device(id: &str) -> PairedDevice {
        PairedDevice { id: id.to_owned(), name: "Pixel".to_owned(), public_key: vec![1, 2, 3], last_seen_unix: 5 }
    }

    fn open(store: &Arc<InMemorySecretStore>) -> SecretPins {
        SecretPins::open(store.clone()).expect("the store reads")
    }

    fn put(store: &InMemorySecretStore, bytes: &[u8]) {
        assert!(store.write(STORAGE_NAME, bytes));
    }

    #[test]
    fn a_saved_list_reads_back() {
        let store = Arc::new(InMemorySecretStore::default());
        assert!(open(&store).record(&device("a")));
        let reopened = open(&store);
        assert_eq!(reopened.devices().len(), 1);
        assert!(reopened.load_problem().is_none());
    }

    #[test]
    fn a_list_that_is_not_json_is_kept_as_a_copy_and_not_read_as_empty() {
        let store = Arc::new(InMemorySecretStore::default());
        put(&store, b"{ not a list");
        let pins = open(&store);
        assert!(pins.devices().is_empty());
        assert!(pins.load_problem().is_some());
        assert_eq!(store.read(KEPT_COPY_NAME).expect("reads"), Some(b"{ not a list".to_vec()));
    }

    #[test]
    fn an_unreadable_list_is_not_overwritten_by_the_next_pairing() {
        let store = Arc::new(InMemorySecretStore::default());
        put(&store, b"garbage");
        let pins = open(&store);
        assert!(!pins.record(&device("new")));
        assert_eq!(store.read(STORAGE_NAME).expect("reads"), Some(b"garbage".to_vec()));
    }

    #[test]
    fn an_unreadable_list_refuses_forgetting_and_leaves_the_bytes_alone() {
        let store = Arc::new(InMemorySecretStore::default());
        put(&store, b"garbage");
        let pins = open(&store);
        assert!(!pins.revoke("anyone"));
        pins.mark_seen("anyone", 9);
        assert_eq!(store.read(STORAGE_NAME).expect("reads"), Some(b"garbage".to_vec()));
    }

    #[test]
    fn one_entry_with_a_broken_key_makes_the_whole_list_unreadable() {
        let store = Arc::new(InMemorySecretStore::default());
        let list = br#"[{"id":"a","name":"A","public_key":"010203","last_seen_unix":1},{"id":"b","name":"B","public_key":"zz","last_seen_unix":1}]"#;
        put(&store, list);
        let pins = open(&store);
        assert!(pins.load_problem().is_some());
        assert!(pins.pin_for("a").is_none());
        assert_eq!(store.read(STORAGE_NAME).expect("reads"), Some(list.to_vec()));
    }

    #[test]
    fn the_problem_says_whether_a_copy_was_kept() {
        let store = Arc::new(InMemorySecretStore::default());
        put(&store, b"garbage");
        store.set_fail_writes(true);
        let without_copy = open(&store).load_problem().expect("a problem");
        store.set_fail_writes(false);
        let with_copy = open(&store).load_problem().expect("a problem");
        assert_ne!(without_copy, with_copy);
    }

    #[test]
    fn a_store_that_cannot_be_read_fails_the_open() {
        let store = Arc::new(InMemorySecretStore::default());
        store.set_fail_reads(true);
        assert!(SecretPins::open(store.clone()).is_err());
    }

    #[test]
    fn a_list_that_decodes_but_is_empty_is_a_normal_empty_list() {
        let store = Arc::new(InMemorySecretStore::default());
        put(&store, b"[]");
        let pins = open(&store);
        assert!(pins.load_problem().is_none());
        assert!(pins.record(&device("a")));
    }
}
