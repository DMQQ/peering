//! The relay-time counter's second home, on disk, written by a thread of its own.
//!
//! An append-only file with one JSON object per charge (`{"c":"<device id>","w":<window>,"s":<seconds>}`).
//! Serde rather than a hand-rolled format so a client id holding a pipe or a newline is stored and
//! read back unchanged, and one object per line so a machine that died mid-append costs one
//! charge rather than the file.
//!
//! **Nothing on the metering path waits for the disk.** A charge is queued to the writer thread,
//! which batches whatever has accumulated into one write and one `fsync`. The tracker's map is the
//! truth for the running process; the file bounds what a restart gives away. Anything the file
//! cannot take stays in the writer's own copy of the totals and is written out whole the next time
//! the file can be replaced, so a full disk loses nothing that a later rewrite can save.
//!
//! Compaction and reopening are retried with a growing delay, never on every charge: a rewrite
//! that fails once will usually fail again at once, and a relay that retried it per append would
//! spend its time on that.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tracing::warn;

/// Seconds a client has used in one window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct WindowUsage {
    pub window: u64,
    pub seconds: u64,
}

pub(crate) type Totals = HashMap<String, WindowUsage>;

#[derive(Serialize, Deserialize)]
struct UsageLine {
    /// The client's device id.
    c: String,
    /// The window the seconds belong to.
    w: u64,
    /// Seconds relayed in that window, for that one charge. What is read back is their sum.
    s: u64,
}

/// How large the log may grow before it is rewritten down to one line per client.
///
/// The test is "big *and* at most half of it would survive", not size alone: a file of distinct
/// clients has nothing to coalesce, and a rewrite that does not shrink it would happen again on
/// the next charge.
pub(crate) const COMPACT_BYTES: u64 = 4 * 1024 * 1024;

/// Charges queued for the writer before new ones are left out of the file (they still count in
/// memory).
const QUEUE_DEPTH: usize = 8192;
const MAX_BATCH: usize = 512;
/// The writer's copy of the totals. Twice the tracker's own ceiling, because it is trimmed less often.
const MAX_MIRRORED_CLIENTS: usize = 40_000;
const BACKOFF_FIRST: Duration = Duration::from_secs(5);
const BACKOFF_LONGEST: Duration = Duration::from_secs(10 * 60);

/// Growing delay between attempts at something that failed.
#[derive(Default)]
struct Backoff {
    failures: u32,
    retry_at: Option<Instant>,
}

impl Backoff {
    fn ready(&self, now: Instant) -> bool {
        self.retry_at.is_none_or(|at| now >= at)
    }

    fn failed(&mut self, now: Instant) {
        let delay = BACKOFF_FIRST.saturating_mul(1u32 << self.failures.min(10)).min(BACKOFF_LONGEST);
        self.failures = self.failures.saturating_add(1);
        self.retry_at = Some(now + delay);
    }

    fn succeeded(&mut self) {
        *self = Self::default();
    }
}

/// The file and the totals it should hold. Lives on the writer thread only.
struct UsageLog {
    path: PathBuf,
    /// Absent when the last attempt to replace or reopen the file failed.
    file: Option<File>,
    /// Bytes in the file, so compaction can be decided without asking the filesystem.
    written: u64,
    totals: Totals,
    full_reported: bool,
    reopen: Backoff,
    compaction: Backoff,
}

struct Charge {
    client_id: String,
    window: u64,
    secs: u64,
}

impl UsageLog {
    /// Opens the log and reads back what it already held. The parent directory is created if it
    /// is missing: the likeliest reason a configured path does not exist yet is that the operator
    /// has just written the line into the environment file.
    fn open(path: PathBuf, now_window: u64) -> io::Result<(Self, Totals)> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)?;
        }
        let usage = Self::replay(&path, now_window)?;
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        let written = file.metadata().map(|m| m.len()).unwrap_or(0);
        let log = Self {
            path,
            file: Some(file),
            written,
            totals: usage.clone(),
            full_reported: false,
            reopen: Backoff::default(),
            compaction: Backoff::default(),
        };
        Ok((log, usage))
    }

    /// The totals, rebuilt from the file.
    ///
    /// **Only the newest window survives**, and a window more than one day ahead of `now_window`
    /// is not the newest, it is a clock that jumped forward when the line was written. Believing it
    /// would discard every real window below it and the relay would give the day away.
    ///
    /// A line that will not parse is skipped rather than made fatal.
    fn replay(path: &Path, now_window: u64) -> io::Result<Totals> {
        let text = match fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(HashMap::new()),
            Err(error) => return Err(error),
        };

        let ceiling = now_window.saturating_add(1);
        let mut newest = 0u64;
        let mut entries = Vec::new();
        for line in text.lines() {
            let Ok(entry) = serde_json::from_str::<UsageLine>(line) else { continue };
            if entry.w > ceiling {
                continue;
            }
            newest = newest.max(entry.w);
            entries.push(entry);
        }

        let mut usage = Totals::new();
        for entry in entries.into_iter().filter(|entry| entry.w == newest) {
            let slot = usage.entry(entry.c).or_insert(WindowUsage { window: newest, seconds: 0 });
            slot.seconds = slot.seconds.saturating_add(entry.s);
        }
        Ok(usage)
    }

    /// Takes a batch: updates the totals, then gets the batch onto the disk with one `fsync`, or
    /// leaves it in the totals for a later rewrite when the file cannot take it.
    fn apply(&mut self, batch: &[Charge], now: Instant) {
        let Some(window) = batch.iter().map(|charge| charge.window).max() else { return };
        let mut accepted = Vec::with_capacity(batch.len());
        for charge in batch {
            if !self.totals.contains_key(&charge.client_id) && !self.has_room_for_new_id(window) {
                continue;
            }
            let entry = self
                .totals
                .entry(charge.client_id.clone())
                .or_insert(WindowUsage { window: charge.window, seconds: 0 });
            if entry.window != charge.window {
                *entry = WindowUsage { window: charge.window, seconds: 0 };
            }
            entry.seconds = entry.seconds.saturating_add(charge.secs);
            accepted.push(charge);
        }

        if self.file.is_none() {
            if self.reopen.ready(now) {
                match self.rewrite(window) {
                    Ok(()) => self.reopen.succeeded(),
                    Err(error) => {
                        warn!(%error, "could not reopen the usage log; charges are kept in memory and it will be retried");
                        self.reopen.failed(now);
                    }
                }
            }
            return;
        }

        if let Err(error) = self.append(&accepted) {
            warn!(%error, "could not write to the usage log; charges are kept in memory and it will be rewritten");
            self.file = None;
            self.reopen.failed(now);
            return;
        }

        if self.needs_compaction(window) && self.compaction.ready(now) {
            match self.rewrite(window) {
                Ok(()) => self.compaction.succeeded(),
                Err(error) => {
                    warn!(%error, "could not compact the usage log; it will be tried again later");
                    self.compaction.failed(now);
                }
            }
        }
    }

    fn append(&mut self, batch: &[&Charge]) -> io::Result<()> {
        let Some(file) = self.file.as_mut() else { return Ok(()) };
        let mut text = String::new();
        for charge in batch {
            let line = serde_json::to_string(&UsageLine {
                c: charge.client_id.clone(),
                w: charge.window,
                s: charge.secs,
            })
            .map_err(io::Error::other)?;
            text.push_str(&line);
            text.push('\n');
        }
        file.write_all(text.as_bytes())?;
        file.sync_data()?;
        self.written += text.len() as u64;
        Ok(())
    }

    /// A new id past the cap is refused outright, after dropping ids from older windows: the
    /// tracker evicts at half this size, so only a flood of fresh ids reaches it.
    fn has_room_for_new_id(&mut self, window: u64) -> bool {
        if self.totals.len() < MAX_MIRRORED_CLIENTS {
            return true;
        }
        self.totals.retain(|_, usage| usage.window == window);
        if self.totals.len() < MAX_MIRRORED_CLIENTS {
            return true;
        }
        if !self.full_reported {
            self.full_reported = true;
            warn!(limit = MAX_MIRRORED_CLIENTS, "the usage log is tracking its maximum of clients; new ones are not recorded");
        }
        false
    }

    fn needs_compaction(&self, window: u64) -> bool {
        if self.written < COMPACT_BYTES {
            return false;
        }
        self.written >= 2 * Self::compacted_size(&self.totals, window)
    }

    /// What the file would weigh after a rewrite, near enough to decide with. The id is counted at
    /// its own length because peers choose it and it can be 256 bytes.
    fn compacted_size(totals: &Totals, window: u64) -> u64 {
        const LINE_OVERHEAD: u64 = 24;
        totals
            .iter()
            .filter(|(_, usage)| usage.window == window && usage.seconds > 0)
            .map(|(id, usage)| LINE_OVERHEAD + id.len() as u64 + usage.seconds.to_string().len() as u64)
            .sum()
    }

    /// Replaces the file with one line per client for `window`, through a temporary file and a
    /// rename so a crash leaves the old log whole.
    ///
    /// After the rename the old handle points at an unlinked file, where appends succeed and are
    /// never seen again, so the handle is dropped before the file is reopened: a failed reopen
    /// must leave no handle rather than that one.
    fn rewrite(&mut self, window: u64) -> io::Result<()> {
        let mut body = String::new();
        for (client_id, usage) in &self.totals {
            if usage.window != window || usage.seconds == 0 {
                continue;
            }
            let line = serde_json::to_string(&UsageLine { c: client_id.clone(), w: window, s: usage.seconds })
                .map_err(io::Error::other)?;
            body.push_str(&line);
            body.push('\n');
        }

        let temporary = self.path.with_extension("log.tmp");
        if let Err(error) = fs::write(&temporary, &body).and_then(|()| fs::rename(&temporary, &self.path)) {
            let _ = fs::remove_file(&temporary);
            return Err(error);
        }
        self.file = None;
        let file = OpenOptions::new().create(true).append(true).open(&self.path)?;
        self.written = file.metadata().map(|m| m.len()).unwrap_or(body.len() as u64);
        self.file = Some(file);
        Ok(())
    }
}

enum Message {
    Charge(Charge),
    Flush(SyncSender<()>),
    Shutdown,
}

fn run(mut log: UsageLog, messages: Receiver<Message>) {
    loop {
        let Ok(first) = messages.recv() else { return };
        let mut charges = Vec::new();
        let mut flushes = Vec::new();
        let mut stop = false;
        let mut next = Some(first);
        while let Some(message) = next.take() {
            match message {
                Message::Charge(charge) => charges.push(charge),
                Message::Flush(reply) => flushes.push(reply),
                Message::Shutdown => {
                    stop = true;
                    break;
                }
            }
            if charges.len() < MAX_BATCH {
                next = messages.try_recv().ok();
            }
        }
        log.apply(&charges, Instant::now());
        for reply in flushes {
            let _ = reply.send(());
        }
        if stop {
            return;
        }
    }
}

/// The metering path's end of the writer. Dropping it drains the queue and joins the thread.
pub(crate) struct UsageLogWriter {
    queue: SyncSender<Message>,
    thread: Option<JoinHandle<()>>,
}

/// A way to wait for the writer without borrowing the tracker's lock.
pub(crate) struct Flusher(SyncSender<Message>);

impl Flusher {
    pub fn flush(&self) {
        let (reply, done) = mpsc::sync_channel(1);
        if self.0.send(Message::Flush(reply)).is_ok() {
            let _ = done.recv();
        }
    }
}

impl UsageLogWriter {
    pub fn open(path: PathBuf, now_window: u64) -> io::Result<(Self, Totals)> {
        let (log, usage) = UsageLog::open(path, now_window)?;
        let (queue, messages) = mpsc::sync_channel(QUEUE_DEPTH);
        let thread = thread::Builder::new()
            .name("usage-log".into())
            .spawn(move || run(log, messages))?;
        Ok((Self { queue, thread: Some(thread) }, usage))
    }

    /// Queues a charge. False when the queue is full, in which case the charge is in memory only.
    pub fn charge(&self, client_id: &str, window: u64, secs: u64) -> bool {
        let charge = Charge { client_id: client_id.to_owned(), window, secs };
        !matches!(self.queue.try_send(Message::Charge(charge)), Err(TrySendError::Full(_)))
    }

    pub fn flusher(&self) -> Flusher {
        Flusher(self.queue.clone())
    }
}

impl Drop for UsageLogWriter {
    fn drop(&mut self) {
        let _ = self.queue.send(Message::Shutdown);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WINDOW: u64 = 20_000;

    fn scratch(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("peeringd-usagelog-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        path.join("usage.log")
    }

    fn charge(client: &str, secs: u64) -> Charge {
        Charge { client_id: client.into(), window: WINDOW, secs }
    }

    fn read_back(path: &Path) -> Totals {
        UsageLog::replay(path, WINDOW).unwrap()
    }

    #[test]
    fn a_batch_is_written_in_one_go_and_replays() {
        let path = scratch("batch");
        let (mut log, _) = UsageLog::open(path.clone(), WINDOW).unwrap();
        log.apply(&[charge("a", 5), charge("a", 7), charge("b", 1)], Instant::now());
        let usage = read_back(&path);
        assert_eq!(usage["a"], WindowUsage { window: WINDOW, seconds: 12 });
        assert_eq!(usage["b"], WindowUsage { window: WINDOW, seconds: 1 });
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_window_more_than_a_day_ahead_is_ignored_on_replay() {
        let path = scratch("future");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let text = format!(
            "{{\"c\":\"phone\",\"w\":{WINDOW},\"s\":300}}\n{{\"c\":\"phone\",\"w\":{},\"s\":999}}\n",
            WINDOW + 40
        );
        fs::write(&path, text).unwrap();
        assert_eq!(read_back(&path)["phone"], WindowUsage { window: WINDOW, seconds: 300 });
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn tomorrows_window_is_still_believed() {
        let path = scratch("tomorrow");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, format!("{{\"c\":\"phone\",\"w\":{},\"s\":60}}\n", WINDOW + 1)).unwrap();
        assert_eq!(read_back(&path)["phone"], WindowUsage { window: WINDOW + 1, seconds: 60 });
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_failed_reopen_keeps_charging_and_is_not_retried_at_once() {
        let path = scratch("reopen");
        let (mut log, _) = UsageLog::open(path.clone(), WINDOW).unwrap();
        let start = Instant::now();
        log.apply(&[charge("a", 5)], start);

        log.file = None;
        log.reopen.failed(start);
        log.apply(&[charge("a", 10)], start + Duration::from_secs(1));
        assert!(log.file.is_none(), "inside the delay no reopen is attempted");
        assert_eq!(log.totals["a"].seconds, 15, "and the charge is still counted");
        assert_eq!(read_back(&path)["a"].seconds, 5, "though the file does not have it yet");

        log.apply(&[charge("a", 1)], start + BACKOFF_FIRST + Duration::from_secs(1));
        assert!(log.file.is_some());
        assert_eq!(read_back(&path)["a"].seconds, 16, "the rewrite carries everything the file missed");
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_failed_compaction_waits_before_the_next_attempt() {
        let path = scratch("compactfail");
        let (mut log, _) = UsageLog::open(path.clone(), WINDOW).unwrap();
        fs::create_dir(path.with_extension("log.tmp")).unwrap();
        log.written = COMPACT_BYTES + 1;
        let start = Instant::now();
        log.apply(&[charge("a", 5)], start);
        assert!(log.file.is_some(), "the old file is still the one being appended to");
        assert!(!log.compaction.ready(start + Duration::from_secs(1)));

        fs::remove_dir(path.with_extension("log.tmp")).unwrap();
        log.apply(&[charge("a", 5)], start + Duration::from_secs(2));
        assert!(log.written > COMPACT_BYTES, "no rewrite was tried inside the delay");

        log.apply(&[charge("a", 5)], start + BACKOFF_FIRST + Duration::from_secs(1));
        assert!(log.written < COMPACT_BYTES, "after the delay the rewrite runs");
        assert_eq!(read_back(&path)["a"].seconds, 15);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn the_backoff_grows_and_stops_growing() {
        let start = Instant::now();
        let mut backoff = Backoff::default();
        assert!(backoff.ready(start));
        backoff.failed(start);
        assert!(!backoff.ready(start + Duration::from_secs(4)));
        assert!(backoff.ready(start + Duration::from_secs(5)));
        backoff.failed(start);
        assert!(!backoff.ready(start + Duration::from_secs(9)));
        for _ in 0..40 {
            backoff.failed(start);
        }
        assert!(backoff.ready(start + BACKOFF_LONGEST));
        backoff.succeeded();
        assert!(backoff.ready(start));
    }

    #[test]
    fn compaction_is_not_attempted_when_there_is_nothing_to_drop() {
        let path = scratch("nothingtodrop");
        let (mut log, _) = UsageLog::open(path.clone(), WINDOW).unwrap();
        for i in 0..20_000 {
            log.totals.insert(format!("{i:-<200}"), WindowUsage { window: WINDOW, seconds: 60 });
        }
        assert!(UsageLog::compacted_size(&log.totals, WINDOW) > COMPACT_BYTES);
        log.written = COMPACT_BYTES + 1;
        assert!(!log.needs_compaction(WINDOW));
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn compaction_is_attempted_when_there_is_something_to_drop() {
        let path = scratch("somethingtodrop");
        let (mut log, _) = UsageLog::open(path.clone(), WINDOW).unwrap();
        log.totals.insert("phone".into(), WindowUsage { window: WINDOW, seconds: 3_600 });
        for i in 0..1_000 {
            log.totals.insert(format!("yesterday-{i}"), WindowUsage { window: WINDOW - 1, seconds: 3_600 });
        }
        log.written = COMPACT_BYTES + 1;
        assert!(log.needs_compaction(WINDOW));
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn the_writer_thread_drains_its_queue_when_dropped() {
        let path = scratch("drain");
        let (writer, _) = UsageLogWriter::open(path.clone(), WINDOW).unwrap();
        for _ in 0..100 {
            assert!(writer.charge("phone", WINDOW, 2));
        }
        drop(writer);
        assert_eq!(read_back(&path)["phone"].seconds, 200);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn flush_waits_until_earlier_charges_are_on_disk() {
        let path = scratch("flush");
        let (writer, _) = UsageLogWriter::open(path.clone(), WINDOW).unwrap();
        writer.charge("phone", WINDOW, 9);
        writer.flusher().flush();
        assert_eq!(read_back(&path)["phone"].seconds, 9);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_new_id_past_the_cap_is_neither_tracked_nor_written() {
        let path = scratch("cap");
        let (mut log, _) = UsageLog::open(path.clone(), WINDOW).unwrap();
        for n in 0..MAX_MIRRORED_CLIENTS {
            log.totals.insert(format!("filler-{n}"), WindowUsage { window: WINDOW, seconds: 1 });
        }
        log.apply(&[charge("newcomer", 5), charge("filler-0", 9)], Instant::now());
        assert!(!log.totals.contains_key("newcomer"));
        assert_eq!(log.totals.len(), MAX_MIRRORED_CLIENTS);
        assert_eq!(log.totals["filler-0"].seconds, 10, "an id already tracked is still charged");
        let on_disk = read_back(&path);
        assert!(!on_disk.contains_key("newcomer"), "the file does not grow with ids that were refused");
        assert_eq!(on_disk["filler-0"].seconds, 9);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn ids_from_an_older_window_make_room_for_a_new_one() {
        let path = scratch("capold");
        let (mut log, _) = UsageLog::open(path.clone(), WINDOW).unwrap();
        for n in 0..MAX_MIRRORED_CLIENTS {
            log.totals.insert(format!("old-{n}"), WindowUsage { window: WINDOW - 1, seconds: 1 });
        }
        log.apply(&[charge("newcomer", 5)], Instant::now());
        assert_eq!(log.totals["newcomer"].seconds, 5);
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }
}
