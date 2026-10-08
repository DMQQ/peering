//! Which public key each device ID was last proved with.
//!
//! **What this is for.** A Mac proves its device ID with a signature, and this records the key that
//! proof was made with. The one thing it enforces is that a registration offering *no* proof cannot
//! claim an ID that has been proved before: "I cannot sign for this" is a different statement from
//! "I am an older build", and only one of them is innocent.
//!
//! **What this used to be, and why it changed.** A device ID used to belong to whoever proved it
//! *first*, and every later registration with a different key was refused permanently, on the
//! reasoning that the ID is only broadcast on the Mac's own network and that the Mac registers
//! within seconds of starting. Both halves of that are false. The ID travels in the pairing QR
//! code, so it reaches whatever the user shows it to, and a Mac that is asleep or switched off is
//! not registering at all, which gives a stranger all the time in the world to arrive first with a
//! key of their own. The device is then the one refused, for ever, until an operator edits this
//! file: a public ID was enough to take a Mac off the relay permanently.
//!
//! So a **proved** registration now always wins. If the key differs from the one on file, the
//! binding moves to it and the change is logged loudly, because a Mac whose key has genuinely
//! changed and an attacker who has just taken the ID look identical here and only a human can tell
//! them apart. The protection against being *impersonated* does not live in this file and never
//! did: it is the pin, which the phone holds and checks against the key the Mac presents during
//! the TLS handshake. A registration this file lets through still cannot be connected to.

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tracing::warn;

/// One line of the binding store.
#[derive(Serialize, Deserialize)]
struct BindingLine {
    /// The device id.
    d: String,
    /// The public key it first proved itself with, as hex.
    k: String,
}

/// What a registration's proof turned out to be worth.
#[derive(Debug, PartialEq, Eq)]
pub enum Binding {
    /// Nothing was known about this ID and it is now bound to the key presented.
    Bound,
    /// The key matches what this ID was bound to.
    Matched,
    /// This ID was bound to a different key and now belongs to this one.
    ///
    /// Worth its own case rather than folded into ``Bound``: it is the one outcome an operator has
    /// to be able to find in a journal, because it is either a device that re-minted its identity
    /// or somebody who has taken an ID they do not own, and nothing here can tell those apart.
    Rebound,
    /// The ID is bound and this registration offers no proof, so it cannot be what it claims.
    Refused(&'static str),
}

pub struct DeviceBindings {
    /// Absent when no path was configured, which is a relay that forgets on restart.
    store: Option<PathBuf>,
    inner: Mutex<HashMap<String, String>>,
}

/// A store with nothing in it and nowhere to write, which is what `HostRegistry::new` builds and
/// what every test that is not about bindings uses.
impl Default for DeviceBindings {
    fn default() -> Self {
        Self {
            store: None,
            inner: Mutex::new(HashMap::new()),
        }
    }
}

impl DeviceBindings {
    pub fn new(path: Option<PathBuf>) -> (Self, Option<io::Error>) {
        let (inner, failure) = match &path {
            // The directory is made first, because the likeliest reason a configured path does not
            // exist is that the operator has just written the line into the environment file and
            // not yet created what it points at. Without this the store silently never records
            // anything, which looks exactly like a store that works until the next restart.
            Some(path) => match Self::prepare(path).and_then(|_| Self::replay(path)) {
                Ok(inner) => (inner, None),
                Err(error) => (HashMap::new(), Some(error)),
            },
            None => (HashMap::new(), None),
        };
        (
            Self {
                store: path,
                inner: Mutex::new(inner),
            },
            failure,
        )
    }

    fn prepare(path: &PathBuf) -> io::Result<()> {
        match path.parent().filter(|p| !p.as_os_str().is_empty()) {
            Some(parent) => fs::create_dir_all(parent),
            None => Ok(()),
        }
    }

    /// Reads back who was bound to what.
    ///
    /// **The last line for an ID wins**, which is the opposite of what this did while a binding was
    /// permanent. It has to be: a re-bind writes a new line, and replaying the first one would put
    /// the store back into the state the re-bind had just replaced, so a Mac that re-minted its
    /// key would work until the relay restarted and then be refused again by its own history.
    fn replay(path: &PathBuf) -> io::Result<HashMap<String, String>> {
        let text = match fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(HashMap::new()),
            Err(error) => return Err(error),
        };

        let mut bindings = HashMap::new();
        for line in text.lines() {
            let Ok(entry) = serde_json::from_str::<BindingLine>(line) else { continue };
            bindings.insert(entry.d, entry.k);
        }
        Ok(bindings)
    }

    /// Decides what to do with a registration, and records what it decided.
    ///
    /// `proof` is the hex public key the registration proved control of, or `None` when it offered
    /// no proof at all. See the module comment for why a proved registration always wins, and why
    /// that is not the same as trusting it: the phone's pin is what decides whether the device
    /// behind this ID is the one it paired with.
    pub fn check_and_bind(&self, device_id: &str, proof: Option<&str>) -> Binding {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());

        match (inner.get(device_id), proof) {
            (Some(bound), Some(present)) if bound == present => Binding::Matched,
            (Some(_), Some(present)) => {
                inner.insert(device_id.to_string(), present.to_string());
                self.record(device_id, present);
                Binding::Rebound
            }
            (Some(_), None) => Binding::Refused(
                "that device id has proved itself before and this registration does not",
            ),
            (None, Some(present)) => {
                inner.insert(device_id.to_string(), present.to_string());
                self.record(device_id, present);
                Binding::Bound
            }
            (None, None) => Binding::Bound,
        }
    }

    /// Writes a new binding down, if there is anywhere to write it.
    ///
    /// A failure here is logged and not returned: the binding has already taken effect in memory,
    /// and refusing a registration because the state directory filled up would turn a bookkeeping
    /// problem into an outage.
    fn record(&self, device_id: &str, public_key: &str) {
        let Some(path) = &self.store else { return };
        let Ok(mut line) = serde_json::to_string(&BindingLine {
            d: device_id.to_string(),
            k: public_key.to_string(),
        }) else {
            return;
        };
        line.push('\n');

        let written = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .and_then(|mut file| file.write_all(line.as_bytes()));
        if let Err(error) = written {
            warn!(%error, "could not record a device binding; it will not survive a restart");
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("peeringd-bindings-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        path.join("devices.jsonl")
    }

    #[test]
    fn first_use_binds_and_the_same_key_matches() {
        let (bindings, failure) = DeviceBindings::new(None);
        assert!(failure.is_none());
        assert_eq!(bindings.check_and_bind("mac", Some("04aa")), Binding::Bound);
        assert_eq!(bindings.check_and_bind("mac", Some("04aa")), Binding::Matched);
    }

    /// **The lockout this used to be.** A device ID is public (it travels in the pairing QR code),
    /// so a stranger who registers it first with a key of their own used to make the real Mac
    /// unreachable for ever: every later registration from the Mac was refused, and only an
    /// operator editing the bindings file could undo it. A proved registration now takes the ID
    /// back, and the change is reported so a human can look at it.
    #[test]
    fn a_different_key_takes_the_id_back_rather_than_locking_the_device_out() {
        let (bindings, _) = DeviceBindings::new(None);
        assert_eq!(bindings.check_and_bind("mac", Some("04aa")), Binding::Bound);

        assert_eq!(bindings.check_and_bind("mac", Some("04bb")), Binding::Rebound);
        assert_eq!(
            bindings.check_and_bind("mac", Some("04bb")),
            Binding::Matched,
            "and the new key is the one on file"
        );
        assert_eq!(bindings.len(), 1, "one id, one binding, never two");
    }

    /// And it survives a restart, which is the part replaying the *first* line got wrong: the Mac
    /// would work until the relay restarted and then be refused by its own history.
    #[test]
    fn a_rebound_key_is_what_survives_a_restart() {
        let path = scratch("rebound");
        let (first, _) = DeviceBindings::new(Some(path.clone()));
        first.check_and_bind("mac", Some("04aa"));
        first.check_and_bind("mac", Some("04bb"));

        let (second, _) = DeviceBindings::new(Some(path.clone()));
        assert_eq!(second.check_and_bind("mac", Some("04bb")), Binding::Matched);
        assert_eq!(second.check_and_bind("mac", Some("04aa")), Binding::Rebound);

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    /// The one that makes this safe to ship before every Mac has updated: an older build that
    /// sends no proof is refused only for IDs that have already been proved, so the protection
    /// arrives per device rather than on a flag day.
    #[test]
    fn a_proofless_registration_is_refused_once_the_id_is_claimed() {
        let (bindings, _) = DeviceBindings::new(None);
        // An older Mac, which has proved nothing, still registers: this is what keeps the fleet
        // working on the day the relay ships.
        assert_eq!(bindings.check_and_bind("old-mac", None), Binding::Bound);

        // And one that has proved itself refuses the same claim from anyone else.
        bindings.check_and_bind("new-mac", Some("04aa"));
        assert!(matches!(bindings.check_and_bind("new-mac", None), Binding::Refused(_)));
    }

    #[test]
    fn two_devices_do_not_share_a_binding() {
        let (bindings, _) = DeviceBindings::new(None);
        bindings.check_and_bind("one", Some("04aa"));
        bindings.check_and_bind("two", Some("04bb"));
        assert_eq!(bindings.check_and_bind("one", Some("04aa")), Binding::Matched);
        assert_eq!(bindings.check_and_bind("two", Some("04bb")), Binding::Matched);
    }

    #[test]
    fn bindings_survive_a_restart() {
        let path = scratch("restart");
        let (first, failure) = DeviceBindings::new(Some(path.clone()));
        assert!(failure.is_none());
        first.check_and_bind("mac", Some("04aa"));

        let (second, failure) = DeviceBindings::new(Some(path.clone()));
        assert!(failure.is_none());
        assert_eq!(
            second.check_and_bind("mac", Some("04aa")),
            Binding::Matched,
            "the restart did not forget who owns the id"
        );
        // And a different key still takes the id back after the restart, rather than being
        // refused by a file that remembers the key it replaced. See the rebound test above.
        assert_eq!(second.check_and_bind("mac", Some("04bb")), Binding::Rebound);

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    /// A store that cannot be read must not become a store that says yes to everything.
    #[test]
    fn a_torn_last_line_costs_one_binding_and_not_the_file() {
        let path = scratch("torn");
        let (bindings, _) = DeviceBindings::new(Some(path.clone()));
        bindings.check_and_bind("one", Some("04aa"));
        bindings.check_and_bind("two", Some("04bb"));

        let mut text = fs::read_to_string(&path).unwrap();
        text.push_str("{\"d\":\"three\",\"k\":");
        fs::write(&path, text).unwrap();

        let (restarted, _) = DeviceBindings::new(Some(path.clone()));
        assert_eq!(restarted.check_and_bind("one", Some("04aa")), Binding::Matched);
        assert_eq!(restarted.check_and_bind("two", Some("04bb")), Binding::Matched);

        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_store_that_cannot_be_opened_still_binds_in_memory() {
        let occupied = scratch("blocked");
        let directory = occupied.parent().unwrap().to_path_buf();
        fs::create_dir_all(&directory).unwrap();
        fs::write(&occupied, b"a file where a directory was expected").unwrap();

        let (bindings, failure) = DeviceBindings::new(Some(occupied.join("devices.jsonl")));
        assert!(failure.is_some(), "the caller should be told");
        assert_eq!(bindings.check_and_bind("mac", Some("04aa")), Binding::Bound);
        // In memory it behaves exactly as it would with a file, which is the point: a store that
        // cannot be written is a store that forgets on restart, not one that refuses registrations.
        assert_eq!(bindings.check_and_bind("mac", Some("04bb")), Binding::Rebound);
        assert_eq!(bindings.check_and_bind("mac", Some("04bb")), Binding::Matched);

        let _ = fs::remove_dir_all(directory);
    }
}
