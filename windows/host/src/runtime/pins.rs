//! The paired devices, kept in the secret store as one JSON list. A failed write leaves the previous list in memory
//! and on disk, so a pairing that could not be saved is reported as not saved.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_core::ports::secret_store::{SecretStore, StoreError};
use peering_core::session::deps::{PairedDevice, PinStore};
use serde::{Deserialize, Serialize};

const STORAGE_NAME: &str = "pairedDevices";

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
}

impl SecretPins {
    /// A read that fails is an error: an empty list here would let the next pairing overwrite every saved device.
    pub fn open(secrets: Arc<dyn SecretStore + Send + Sync>) -> Result<Self, StoreError> {
        let devices = match secrets.read(STORAGE_NAME)? {
            Some(bytes) => decode(&bytes),
            None => Vec::new(),
        };
        Ok(Self { secrets, devices: Mutex::new(devices) })
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

/// A saved value that does not decode is read as no devices, as an unreadable pin list is a corrupt file, not a secret.
fn decode(bytes: &[u8]) -> Vec<PairedDevice> {
    let stored: Vec<StoredDevice> = serde_json::from_slice(bytes).unwrap_or_default();
    stored
        .into_iter()
        .filter_map(|device| {
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
