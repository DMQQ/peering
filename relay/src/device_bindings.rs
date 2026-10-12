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
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::Mutex;
use std::thread::JoinHandle;

use serde::{Deserialize, Serialize};
use tracing::warn;

/// Bindings kept, unless `PEERINGD_DEVICE_BINDINGS_MAX` says otherwise. A binding is about a
/// hundred bytes, so this is single-digit megabytes; past it new ids still register but are not
/// bound, which is the behaviour of a relay that had never heard of them.
pub const DEFAULT_MAX_BINDINGS: usize = 100_000;

/// Superseded lines tolerated in the file before it is rewritten.
const COMPACT_SLACK: usize = 1024;

/// Appends waiting for the writer. Beyond this a binding stays in memory only.
const QUEUE_DEPTH: usize = 1024;

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

enum Job {
    Append { device_id: String, public_key: String },
    Flush(SyncSender<()>),
}

/// The thread that owns the file, so a registration never waits on the disk.
struct Writer {
    jobs: Mutex<Option<SyncSender<Job>>>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

pub struct DeviceBindings {
    inner: Mutex<HashMap<String, String>>,
    max_entries: usize,
    /// Absent when no path was configured, which is a relay that forgets on restart.
    writer: Option<Writer>,
}

/// A store with nothing in it and nowhere to write, which is what `HostRegistry::new` builds and
/// what every test that is not about bindings uses.
impl Default for DeviceBindings {
    fn default() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            max_entries: DEFAULT_MAX_BINDINGS,
            writer: None,
        }
    }
}

impl Drop for DeviceBindings {
    fn drop(&mut self) {
        let Some(writer) = &self.writer else { return };
        writer.jobs.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(thread) = writer.thread.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = thread.join();
        }
    }
}

impl DeviceBindings {
    pub fn new(path: Option<PathBuf>) -> (Self, Option<io::Error>) {
        Self::with_limit(path, DEFAULT_MAX_BINDINGS)
    }

    pub fn with_limit(path: Option<PathBuf>, max_entries: usize) -> (Self, Option<io::Error>) {
        let mut bindings = Self::default();
        bindings.max_entries = max_entries;
        let Some(path) = path else { return (bindings, None) };

        // The directory is made first, because the likeliest reason a configured path does not
        // exist is that the operator has just written the line into the environment file and
        // not yet created what it points at. Without this the store silently never records
        // anything, which looks exactly like a store that works until the next restart.
        let loaded = Self::prepare(&path).and_then(|_| Self::replay(&path));
        let (map, lines) = match loaded {
            Ok(loaded) => loaded,
            Err(error) => return (bindings, Some(error)),
        };
        if lines > map.len()
            && let Err(error) = Self::compact(&path, &map)
        {
            warn!(%error, "could not compact the device binding store");
        }

        *bindings.inner.get_mut().unwrap_or_else(|e| e.into_inner()) = map.clone();
        let lines = lines.min(map.len());
        let (jobs, queue) = mpsc::sync_channel(QUEUE_DEPTH);
        let spawned = std::thread::Builder::new()
            .name("device-bindings".into())
            .spawn(move || Self::write_loop(&path, map, lines, queue));
        match spawned {
            Ok(thread) => {
                bindings.writer = Some(Writer {
                    jobs: Mutex::new(Some(jobs)),
                    thread: Mutex::new(Some(thread)),
                });
                (bindings, None)
            }
            Err(error) => (bindings, Some(error)),
        }
    }

    fn prepare(path: &Path) -> io::Result<()> {
        match path.parent().filter(|p| !p.as_os_str().is_empty()) {
            Some(parent) => fs::create_dir_all(parent),
            None => Ok(()),
        }
    }

    /// Reads back who was bound to what, and how many lines it took to say so.
    ///
    /// **The last line for an ID wins**, which is the opposite of what this did while a binding was
    /// permanent. It has to be: a re-bind writes a new line, and replaying the first one would put
    /// the store back into the state the re-bind had just replaced, so a Mac that re-minted its
    /// key would work until the relay restarted and then be refused again by its own history.
    fn replay(path: &Path) -> io::Result<(HashMap<String, String>, usize)> {
        let text = match fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok((HashMap::new(), 0)),
            Err(error) => return Err(error),
        };

        let mut bindings = HashMap::new();
        let mut lines = 0;
        for line in text.lines() {
            let Ok(entry) = serde_json::from_str::<BindingLine>(line) else { continue };
            bindings.insert(entry.d, entry.k);
            lines += 1;
        }
        Ok((bindings, lines))
    }

    /// Rewrites the file as one line per id, through a temporary file so a crash mid-way leaves the
    /// old one in place.
    fn compact(path: &Path, bindings: &HashMap<String, String>) -> io::Result<()> {
        let mut text = String::new();
        for (device_id, public_key) in bindings {
            let line = serde_json::to_string(&BindingLine {
                d: device_id.clone(),
                k: public_key.clone(),
            })
            .map_err(io::Error::other)?;
            text.push_str(&line);
            text.push('\n');
        }
        let mut scratch = path.as_os_str().to_owned();
        scratch.push(".tmp");
        let scratch = PathBuf::from(scratch);
        let mut file = File::create(&scratch)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        fs::rename(&scratch, path)
    }

    fn open_for_append(path: &Path) -> io::Result<File> {
        OpenOptions::new().create(true).append(true).open(path)
    }

    fn write_loop(
        path: &Path,
        mut bindings: HashMap<String, String>,
        mut lines: usize,
        queue: mpsc::Receiver<Job>,
    ) {
        let mut file = Self::open_for_append(path).ok();
        while let Ok(job) = queue.recv() {
            let (device_id, public_key) = match job {
                Job::Flush(done) => {
                    let _ = done.send(());
                    continue;
                }
                Job::Append { device_id, public_key } => (device_id, public_key),
            };
            bindings.insert(device_id.clone(), public_key.clone());

            let written = (|| {
                let mut line = serde_json::to_string(&BindingLine { d: device_id, k: public_key })
                    .map_err(io::Error::other)?;
                line.push('\n');
                if file.is_none() {
                    file = Some(Self::open_for_append(path)?);
                }
                match file.as_mut() {
                    Some(file) => file.write_all(line.as_bytes()),
                    None => Err(io::Error::other("no file")),
                }
            })();
            match written {
                Ok(()) => lines += 1,
                Err(error) => {
                    file = None;
                    warn!(%error, "could not record a device binding; it will not survive a restart");
                    continue;
                }
            }

            if lines > bindings.len() * 2 + COMPACT_SLACK {
                match Self::compact(path, &bindings) {
                    Ok(()) => {
                        lines = bindings.len();
                        file = Self::open_for_append(path).ok();
                    }
                    Err(error) => warn!(%error, "could not compact the device binding store"),
                }
            }
        }
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
            (None, Some(_)) if inner.len() >= self.max_entries => {
                warn!(max = self.max_entries, "the device binding store is full; this id registers unbound");
                Binding::Bound
            }
            (None, Some(present)) => {
                inner.insert(device_id.to_string(), present.to_string());
                self.record(device_id, present);
                Binding::Bound
            }
            (None, None) => Binding::Bound,
        }
    }

    /// Hands a new binding to the writer, if there is anywhere to write it.
    ///
    /// A failure is logged and not returned: the binding has already taken effect in memory, and
    /// refusing a registration because the state directory filled up would turn a bookkeeping
    /// problem into an outage.
    fn record(&self, device_id: &str, public_key: &str) {
        let Some(writer) = &self.writer else { return };
        let jobs = writer.jobs.lock().unwrap_or_else(|e| e.into_inner());
        let Some(jobs) = jobs.as_ref() else { return };
        let job = Job::Append {
            device_id: device_id.to_string(),
            public_key: public_key.to_string(),
        };
        match jobs.try_send(job) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) => {
                warn!("the device binding writer is behind; a binding was kept in memory only")
            }
            Err(TrySendError::Disconnected(_)) => {
                warn!("the device binding writer has stopped; bindings will not survive a restart")
            }
        }
    }

    /// Waits until every binding recorded so far has been written. Blocks the calling thread.
    pub fn flush(&self) {
        let Some(writer) = &self.writer else { return };
        let (done, wait) = mpsc::sync_channel(1);
        let sent = {
            let jobs = writer.jobs.lock().unwrap_or_else(|e| e.into_inner());
            jobs.as_ref().is_some_and(|jobs| jobs.send(Job::Flush(done)).is_ok())
        };
        if sent {
            let _ = wait.recv();
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
        first.flush();

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

        first.flush();
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

        bindings.flush();
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

    fn lines_in(path: &Path) -> usize {
        fs::read_to_string(path).map(|text| text.lines().count()).unwrap_or(0)
    }

    #[test]
    fn rebinding_one_id_over_and_over_does_not_grow_the_file_without_bound() {
        let path = scratch("compact");
        let (bindings, _) = DeviceBindings::new(Some(path.clone()));
        for round in 0..3000 {
            bindings.check_and_bind("mac", Some(&format!("04{round:04x}")));
            if round % 500 == 0 {
                bindings.flush();
            }
        }
        bindings.flush();
        assert!(lines_in(&path) <= 2 + COMPACT_SLACK + 1, "got {} lines", lines_in(&path));

        let (restarted, _) = DeviceBindings::new(Some(path.clone()));
        assert_eq!(restarted.check_and_bind("mac", Some(&format!("04{:04x}", 2999))), Binding::Matched);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_store_with_superseded_lines_is_rewritten_on_open() {
        let path = scratch("startup");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut text = String::new();
        for key in ["04aa", "04bb", "04cc"] {
            text.push_str(&format!("{{\"d\":\"mac\",\"k\":\"{key}\"}}\n"));
        }
        fs::write(&path, text).unwrap();

        let (bindings, _) = DeviceBindings::new(Some(path.clone()));
        assert_eq!(lines_in(&path), 1);
        assert_eq!(bindings.check_and_bind("mac", Some("04cc")), Binding::Matched);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_full_store_registers_new_ids_unbound_and_keeps_the_old_ones() {
        let path = scratch("cap");
        let (bindings, _) = DeviceBindings::with_limit(Some(path.clone()), 2);
        bindings.check_and_bind("one", Some("04aa"));
        bindings.check_and_bind("two", Some("04bb"));
        assert_eq!(bindings.check_and_bind("three", Some("04cc")), Binding::Bound);
        assert_eq!(bindings.len(), 2);
        assert!(matches!(bindings.check_and_bind("one", None), Binding::Refused(_)));
        assert_eq!(bindings.check_and_bind("three", None), Binding::Bound, "unbound, so a proofless claim passes");

        bindings.check_and_bind("one", Some("04dd"));
        bindings.flush();
        assert_eq!(lines_in(&path), 3, "a rebind of a kept id still lands");
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn dropping_the_store_drains_the_writer() {
        let path = scratch("async");
        let (bindings, _) = DeviceBindings::new(Some(path.clone()));
        for n in 0..200 {
            bindings.check_and_bind(&format!("mac-{n}"), Some("04aa"));
        }
        drop(bindings);
        assert_eq!(lines_in(&path), 200, "dropping the store drains the writer");
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }
}
