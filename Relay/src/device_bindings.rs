//! Which public key each device ID has proved itself with.
//!
//! **First use binds, and everything after it must match.** There is no enrolment step here and no
//! authority: a device ID belongs to whoever proved it first, and the proof is a signature with the
//! key that device already had. What makes first-use safe enough is that the ID is a UUID which is
//! only broadcast on the network the Mac itself advertises on, and that the Mac registers within
//! seconds of starting. A stranger has to arrive before a machine that is already running, on the
//! same network as the person they are attacking.
//!
//! **The binding is what makes a proofless registration refusable**, and that is the part worth
//! being precise about. On its own, requiring a proof would break every Mac in the field on the day
//! it shipped, so the relay cannot demand one yet. But it can refuse a registration that has no
//! proof for an ID that somebody has *already* proved: at that point "I cannot sign for this" is a
//! different statement from "I am an older build", and only one of them is innocent. So the
//! protection arrives per device as devices update, with no flag to flip and no cutover.

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
    /// The ID is bound to a different key, or to none and this registration offers no proof.
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
    /// **The first line for an ID wins**, not the last, because the file is a record of first use
    /// and a later line for the same ID would only ever exist if a bug wrote one. Taking the last
    /// instead would quietly turn a bind-once store into a bind-anytime one.
    fn replay(path: &PathBuf) -> io::Result<HashMap<String, String>> {
        let text = match fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(HashMap::new()),
            Err(error) => return Err(error),
        };

        let mut bindings = HashMap::new();
        for line in text.lines() {
            let Ok(entry) = serde_json::from_str::<BindingLine>(line) else { continue };
            bindings.entry(entry.d).or_insert(entry.k);
        }
        Ok(bindings)
    }

    /// Decides what to do with a registration, and records it if it is the first.
    ///
    /// `proof` is the hex public key the registration proved control of, or `None` when it offered
    /// no proof at all. The two refusals it can return are deliberately different sentences: one is
    /// an attacker, the other is a build that predates this, and an operator reading a log needs to
    /// be able to tell them apart while the fleet updates.
    pub fn check_and_bind(&self, device_id: &str, proof: Option<&str>) -> Binding {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());

        match (inner.get(device_id), proof) {
            (Some(bound), Some(present)) if bound == present => Binding::Matched,
            (Some(_), Some(_)) => Binding::Refused(
                "that device id is bound to a different key; a device that loses its key must be \
                 unbound by the operator",
            ),
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

    /// The attack this exists for: somebody who knows the ID but not the key.
    #[test]
    fn a_different_key_cannot_take_a_bound_id() {
        let (bindings, _) = DeviceBindings::new(None);
        bindings.check_and_bind("mac", Some("04aa"));
        assert!(matches!(
            bindings.check_and_bind("mac", Some("04bb")),
            Binding::Refused(_)
        ));
        assert_eq!(bindings.len(), 1, "and the real binding is untouched");
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
        assert!(matches!(
            second.check_and_bind("mac", Some("04bb")),
            Binding::Refused(_)
        ));

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
        assert!(matches!(
            bindings.check_and_bind("mac", Some("04bb")),
            Binding::Refused(_)
        ));

        let _ = fs::remove_dir_all(directory);
    }
}
