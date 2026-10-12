//! The Macs that are currently registered, by device ID.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::{mpsc, Mutex};
use tracing::warn;

use crate::device_bindings::{Binding, DeviceBindings};
use crate::protocol::ServerMessage;
use crate::redact::tag;

#[derive(Clone, Default)]
pub struct HostRegistry {
    inner: Arc<Mutex<HashMap<String, Host>>>,
    /// Who each device id belongs to. It outlives any entry, and every clone must share it: a copy
    /// that started empty would let a registration through on the connection holding it.
    bindings: Arc<DeviceBindings>,
}

struct Host {
    protocol_version: u16,
    /// Whether the registration proved the device key, as opposed to naming an id.
    proven: bool,
    /// The push channel for this Mac's signalling connection.
    tx: mpsc::Sender<ServerMessage>,
}

/// A host's registration, cloned out so the lock is not held while a session is allocated.
pub(super) struct HostRef {
    pub(super) tx: mpsc::Sender<ServerMessage>,
    pub(super) protocol_version: u16,
    pub(super) proven: bool,
}

impl HostRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// The same registry, with device bindings that outlive the process. The failure is returned
    /// so `main` can say at startup which of the two it got.
    pub fn with_bindings(path: Option<PathBuf>, max_bindings: usize) -> (Self, Option<std::io::Error>) {
        let (bindings, failure) = DeviceBindings::with_limit(path, max_bindings);
        (Self { bindings: Arc::new(bindings), ..Self::default() }, failure)
    }

    /// Registers a Mac, if it is entitled to the id it is claiming. `proof` is the public key the
    /// registration proved control of, or `None`: an id nobody has proved is registered by anyone,
    /// and an id somebody has proved is registered only by that device.
    pub(super) async fn put(
        &self,
        device_id: &str,
        version: u16,
        tx: mpsc::Sender<ServerMessage>,
        proof: Option<&str>,
    ) -> Result<(), &'static str> {
        match self.bindings.check_and_bind(device_id, proof) {
            Binding::Refused(reason) => return Err(reason),
            // Loud, because it cannot be judged here: a device that re-minted its identity and a
            // stranger who took an id look the same. Refusing is what let a stranger take a Mac
            // off the relay by arriving first.
            Binding::Rebound => {
                warn!(
                    device_id = %tag(device_id),
                    "this device id was bound to a different key and is now bound to this one"
                );
            }
            Binding::Bound | Binding::Matched => {}
        }

        self.inner.lock().await.insert(
            device_id.to_string(),
            Host { protocol_version: version, proven: proof.is_some(), tx },
        );
        Ok(())
    }

    /// Removes a registration only if this connection still owns it: a Mac that reconnects has its
    /// old socket close after the new one registered, and must not delete the new entry.
    pub(super) async fn remove_if_ours(&self, device_id: &str, tx: &mpsc::Sender<ServerMessage>) {
        let mut inner = self.inner.lock().await;
        if inner.get(device_id).is_some_and(|host| host.tx.same_channel(tx)) {
            inner.remove(device_id);
        }
    }

    /// A host whose connection has gone is not present even if its cleanup never ran.
    pub(super) async fn entry_for(&self, device_id: &str) -> Option<HostRef> {
        let mut inner = self.inner.lock().await;
        if inner.get(device_id).is_some_and(|host| host.tx.is_closed()) {
            inner.remove(device_id);
            return None;
        }
        inner.get(device_id).map(|host| HostRef {
            tx: host.tx.clone(),
            protocol_version: host.protocol_version,
            proven: host.proven,
        })
    }

    pub async fn online_count(&self) -> usize {
        self.inner.lock().await.values().filter(|host| !host.tx.is_closed()).count()
    }

    /// Waits for pending device bindings to reach the disk, for a clean shutdown.
    pub fn flush_bindings(&self) {
        self.bindings.flush();
    }
}
