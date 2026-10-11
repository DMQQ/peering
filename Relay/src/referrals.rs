//! Invite codes, and the extra relay time they earn.
//!
//! **The rule.** Every device has one short code. A device that redeems someone else's code gets
//! one grant, and the owner of the code gets one grant too. A grant adds `bonus_seconds` to the
//! free allowance of every window for `duration_secs` from the moment of redemption. Grants stack,
//! so the bonus a device has at any moment is one grant's worth per grant still running, and that
//! is bounded: a redeemer holds at most one grant ever, and an owner earns from at most
//! `max_paid_invites` redemptions, so nobody holds more than `max_paid_invites` grants.
//!
//! **Identity is a key, never an announced id.** The caller hands in the public key a request
//! proved (see `device_proof::referral_payload`). An id the app invents and loses on reinstall
//! would let one person redeem once per install, and a key survives the reinstall. Making keys is
//! still free for someone who scripts it, which is the same hole the free allowance already has;
//! the daily and total ceilings below are what keep farming it from growing without bound.
//!
//! **What survives a restart** is an append-only file of two kinds of line (a code issued, a code
//! redeemed). Whether the owner earned from a redemption is written into its line, so lowering the
//! cap later does not take back time that was promised.

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Mutex;

use ring::digest;
use serde::{Deserialize, Serialize};
use tracing::warn;

/// Unambiguous when read aloud or typed from a screenshot: no `I`, `L`, `O`, `0` or `1`.
const ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH: usize = 8;

/// Codes that may exist. A code is issued to any key that proves itself, and keys cost nothing to
/// make, so the table needs a ceiling that does not depend on a peer's patience.
const MAX_CODES: usize = 100_000;
/// Redemptions remembered. "Once per device, ever" means they cannot be forgotten, so this is a
/// ceiling on the memory and the file rather than a window.
const MAX_REDEMPTIONS: usize = 50_000;
/// Redemptions the relay accepts per rolling day, across all devices. Slows a script that mints
/// keys to farm bonuses far below the point where it could fill `MAX_REDEMPTIONS`.
const MAX_REDEMPTIONS_PER_DAY: u32 = 1_000;
const DAY_SECS: u64 = 24 * 3600;

/// Longest code string looked at before normalising.
const MAX_CODE_INPUT: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReferralTerms {
    /// Seconds added to each window's allowance by one running grant.
    pub bonus_seconds: u64,
    /// How long a grant runs from the redemption.
    pub duration_secs: u64,
    /// Redemptions of one owner's code that earn the owner a grant.
    pub max_paid_invites: u32,
}

impl Default for ReferralTerms {
    fn default() -> Self {
        Self {
            bonus_seconds: 30 * 60,
            duration_secs: 7 * DAY_SECS,
            max_paid_invites: 5,
        }
    }
}

/// What a device is told about its own standing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Standing {
    pub code: String,
    /// Seconds added to every window's allowance right now.
    pub bonus_seconds: u64,
    /// Unix seconds at which the last running grant ends, if any is running.
    pub bonus_ends_at: Option<u64>,
    /// Whether this device has already redeemed someone's code.
    pub redeemed: bool,
    pub invites_earned: u32,
    pub invites_max: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReferralError {
    UnknownCode,
    OwnCode,
    AlreadyRedeemed,
    /// A ceiling was reached; try again later.
    Busy,
}

impl ReferralError {
    pub fn code(self) -> &'static str {
        match self {
            Self::UnknownCode => "referralUnknownCode",
            Self::OwnCode => "referralOwnCode",
            Self::AlreadyRedeemed => "referralAlreadyRedeemed",
            Self::Busy => "referralsBusy",
        }
    }

    pub fn message(self) -> &'static str {
        match self {
            Self::UnknownCode => "that invite code does not exist",
            Self::OwnCode => "that is this device's own invite code",
            Self::AlreadyRedeemed => "this device has already used an invite code",
            Self::Busy => "invites are unavailable right now; try again later",
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "t")]
enum Line {
    /// A code was issued to a device.
    #[serde(rename = "code")]
    Code { i: String, c: String },
    /// `r` redeemed the code of `o` at `at`; `e` says whether `o` earned a grant from it.
    #[serde(rename = "redeem")]
    Redeem { r: String, o: String, at: u64, e: bool },
}

#[derive(Default)]
struct Inner {
    owner_of: HashMap<String, String>,
    code_of: HashMap<String, String>,
    /// Redeemer to owner, kept for ever: it is what makes redemption once per device.
    redeemed: HashMap<String, String>,
    /// Unix seconds at which each grant of a device ends.
    grants: HashMap<String, Vec<u64>>,
    earned: HashMap<String, u32>,
    /// The day number and how many redemptions were accepted in it.
    today: (u64, u32),
}

pub struct Referrals {
    terms: ReferralTerms,
    store: Option<PathBuf>,
    inner: Mutex<Inner>,
}

impl Referrals {
    /// A store that remembers nothing across a restart.
    pub fn in_memory(terms: ReferralTerms) -> Self {
        Self { terms, store: None, inner: Mutex::new(Inner::default()) }
    }

    /// A store backed by a file, or one that explains why it is not. Always returns a working store
    /// (a relay that will not start over invites is a worse outage than invites that reset).
    pub fn open(terms: ReferralTerms, path: Option<PathBuf>) -> (Self, Option<io::Error>) {
        let Some(path) = path else { return (Self::in_memory(terms), None) };
        match Self::replay(&path, terms.duration_secs) {
            Ok(inner) => (Self { terms, store: Some(path), inner: Mutex::new(inner) }, None),
            Err(error) => (Self::in_memory(terms), Some(error)),
        }
    }

    pub fn terms(&self) -> ReferralTerms {
        self.terms
    }

    fn replay(path: &PathBuf, duration: u64) -> io::Result<Inner> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent)?;
        }
        let text = match fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Inner::default()),
            Err(error) => return Err(error),
        };
        let mut inner = Inner::default();
        for line in text.lines() {
            // A line that will not parse costs that line, not the file: a machine that died
            // mid-append is the case this is written for.
            let Ok(line) = serde_json::from_str::<Line>(line) else { continue };
            match line {
                Line::Code { i, c } => {
                    inner.owner_of.insert(c.clone(), i.clone());
                    inner.code_of.insert(i, c);
                }
                Line::Redeem { r, o, at, e } => {
                    inner.apply_redemption(&r, &o, at, e, duration);
                }
            }
        }
        Ok(inner)
    }

    /// The device's own code and standing, issuing a code the first time it asks.
    pub fn standing(&self, identity: &str, now: u64) -> Result<Standing, ReferralError> {
        let (standing, line) = {
            let mut inner = self.lock();
            let line = inner.ensure_code(identity)?;
            (inner.standing_of(identity, now, self.terms), line)
        };
        if let Some(line) = line {
            self.write(&line);
        }
        Ok(standing)
    }

    /// Redeems `raw_code` for `identity`: one grant to it, and one to the code's owner if the owner
    /// is under the cap.
    pub fn redeem(
        &self,
        identity: &str,
        raw_code: &str,
        now: u64,
    ) -> Result<Standing, ReferralError> {
        let code = normalise(raw_code).ok_or(ReferralError::UnknownCode)?;
        let (standing, lines) = {
            let mut inner = self.lock();
            let owner = inner.owner_of.get(&code).cloned().ok_or(ReferralError::UnknownCode)?;
            if owner == identity {
                return Err(ReferralError::OwnCode);
            }
            if inner.redeemed.contains_key(identity) {
                return Err(ReferralError::AlreadyRedeemed);
            }
            let day = now / DAY_SECS;
            if inner.today.0 != day {
                inner.today = (day, 0);
            }
            if inner.redeemed.len() >= MAX_REDEMPTIONS || inner.today.1 >= MAX_REDEMPTIONS_PER_DAY {
                return Err(ReferralError::Busy);
            }
            let mut lines = Vec::new();
            if let Some(line) = inner.ensure_code(identity)? {
                lines.push(line);
            }
            let earns = inner.earned.get(&owner).copied().unwrap_or(0) < self.terms.max_paid_invites;
            inner.apply_redemption(identity, &owner, now, earns, self.terms.duration_secs);
            inner.today.1 += 1;
            lines.push(Line::Redeem { r: identity.to_string(), o: owner, at: now, e: earns });
            (inner.standing_of(identity, now, self.terms), lines)
        };
        for line in &lines {
            self.write(line);
        }
        Ok(standing)
    }

    /// Seconds added to each window's allowance for this device right now.
    pub fn bonus_seconds(&self, identity: &str, now: u64) -> u64 {
        let inner = self.lock();
        inner.running(identity, now) * self.terms.bonus_seconds
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Logged and carried on with: the change already holds in memory, and refusing an invite
    /// because the state directory filled up would turn bookkeeping into an outage.
    fn write(&self, line: &Line) {
        let Some(path) = &self.store else { return };
        let Ok(mut text) = serde_json::to_string(line) else { return };
        text.push('\n');
        let written = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .and_then(|mut file| file.write_all(text.as_bytes()).and_then(|_| file.sync_data()));
        if let Err(error) = written {
            warn!(%error, "could not record a referral; it will not survive a restart");
        }
    }
}

impl Inner {
    /// Issues the device's code if it has none. The line to persist is returned so the caller can
    /// write it after letting go of the lock.
    fn ensure_code(&mut self, identity: &str) -> Result<Option<Line>, ReferralError> {
        if self.code_of.contains_key(identity) {
            return Ok(None);
        }
        if self.owner_of.len() >= MAX_CODES {
            return Err(ReferralError::Busy);
        }
        // Derived from the identity so the same key always lands on the same first candidate; the
        // counter only matters in the one-in-a-trillion case of a collision.
        let code = (0u32..)
            .map(|attempt| derive_code(identity, attempt))
            .find(|candidate| !self.owner_of.contains_key(candidate))
            .unwrap_or_default();
        self.owner_of.insert(code.clone(), identity.to_string());
        self.code_of.insert(identity.to_string(), code.clone());
        Ok(Some(Line::Code { i: identity.to_string(), c: code }))
    }

    fn apply_redemption(&mut self, redeemer: &str, owner: &str, at: u64, owner_earns: bool, duration: u64) {
        self.redeemed.insert(redeemer.to_string(), owner.to_string());
        let ends = at.saturating_add(duration);
        self.grants.entry(redeemer.to_string()).or_default().push(ends);
        if owner_earns {
            self.grants.entry(owner.to_string()).or_default().push(ends);
            *self.earned.entry(owner.to_string()).or_insert(0) += 1;
        }
    }

    fn running(&self, identity: &str, now: u64) -> u64 {
        self.grants
            .get(identity)
            .map_or(0, |ends| ends.iter().filter(|end| **end > now).count() as u64)
    }

    fn standing_of(&self, identity: &str, now: u64, terms: ReferralTerms) -> Standing {
        let ends = self.grants.get(identity);
        Standing {
            code: self.code_of.get(identity).cloned().unwrap_or_default(),
            bonus_seconds: self.running(identity, now) * terms.bonus_seconds,
            bonus_ends_at: ends.and_then(|ends| ends.iter().copied().filter(|end| *end > now).max()),
            redeemed: self.redeemed.contains_key(identity),
            invites_earned: self.earned.get(identity).copied().unwrap_or(0),
            invites_max: terms.max_paid_invites,
        }
    }
}

fn derive_code(identity: &str, attempt: u32) -> String {
    let mut context = digest::Context::new(&digest::SHA256);
    context.update(identity.as_bytes());
    context.update(&attempt.to_be_bytes());
    let hash = context.finish();
    hash.as_ref()
        .iter()
        .take(CODE_LENGTH)
        .map(|byte| ALPHABET[*byte as usize % ALPHABET.len()] as char)
        .collect()
}

/// Upper case with spaces and hyphens removed, so "abcd-efgh" and "ABCDEFGH" are one code. `None`
/// for anything that cannot be a code.
fn normalise(raw: &str) -> Option<String> {
    if raw.len() > MAX_CODE_INPUT {
        return None;
    }
    let code: String = raw
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .map(|c| c.to_ascii_uppercase())
        .collect();
    (code.len() == CODE_LENGTH && code.bytes().all(|b| ALPHABET.contains(&b))).then_some(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000;

    fn store() -> Referrals {
        Referrals::in_memory(ReferralTerms::default())
    }

    fn code_of(referrals: &Referrals, identity: &str) -> String {
        referrals.standing(identity, NOW).expect("a code is issued").code
    }

    fn scratch(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("peeringd-referrals-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        path.join("referrals.jsonl")
    }

    #[test]
    fn a_code_is_stable_and_made_of_the_unambiguous_alphabet() {
        let referrals = store();
        let first = code_of(&referrals, "key-a");
        assert_eq!(first, code_of(&referrals, "key-a"));
        assert_eq!(first.len(), CODE_LENGTH);
        assert!(first.bytes().all(|b| ALPHABET.contains(&b)));
        assert_ne!(first, code_of(&referrals, "key-b"));
    }

    #[test]
    fn redeeming_gives_both_sides_a_grant() {
        let referrals = store();
        let owner = code_of(&referrals, "owner");
        let standing = referrals.redeem("friend", &owner, NOW).expect("redeems");
        assert_eq!(standing.bonus_seconds, 1800);
        assert!(standing.redeemed);
        assert_eq!(standing.bonus_ends_at, Some(NOW + 7 * DAY_SECS));
        assert_eq!(referrals.bonus_seconds("owner", NOW), 1800);
        assert_eq!(referrals.standing("owner", NOW).unwrap().invites_earned, 1);
    }

    #[test]
    fn a_code_can_be_typed_loosely() {
        let referrals = store();
        let owner = code_of(&referrals, "owner");
        let loose = format!("{}-{}", owner[..4].to_ascii_lowercase(), &owner[4..]);
        assert!(referrals.redeem("friend", &loose, NOW).is_ok());
    }

    #[test]
    fn a_device_redeems_once_ever() {
        let referrals = store();
        let first = code_of(&referrals, "first");
        let second = code_of(&referrals, "second");
        referrals.redeem("friend", &first, NOW).expect("redeems");
        assert_eq!(referrals.redeem("friend", &second, NOW), Err(ReferralError::AlreadyRedeemed));
        assert_eq!(referrals.redeem("friend", &first, NOW + 30 * DAY_SECS), Err(ReferralError::AlreadyRedeemed));
    }

    #[test]
    fn your_own_code_and_unknown_codes_are_refused() {
        let referrals = store();
        let own = code_of(&referrals, "me");
        assert_eq!(referrals.redeem("me", &own, NOW), Err(ReferralError::OwnCode));
        assert_eq!(referrals.redeem("me", "ZZZZZZZZ", NOW), Err(ReferralError::UnknownCode));
        assert_eq!(referrals.redeem("me", "short", NOW), Err(ReferralError::UnknownCode));
        assert_eq!(referrals.redeem("me", "0000 0000", NOW), Err(ReferralError::UnknownCode));
    }

    #[test]
    fn the_owner_stops_earning_at_the_cap_but_the_redeemer_still_does() {
        let referrals = Referrals::in_memory(ReferralTerms { max_paid_invites: 2, ..Default::default() });
        let owner = code_of(&referrals, "owner");
        for friend in ["a", "b", "c"] {
            let standing = referrals.redeem(friend, &owner, NOW).expect("redeems");
            assert_eq!(standing.bonus_seconds, 1800);
        }
        assert_eq!(referrals.bonus_seconds("owner", NOW), 2 * 1800);
        assert_eq!(referrals.standing("owner", NOW).unwrap().invites_earned, 2);
    }

    #[test]
    fn a_grant_ends_exactly_when_its_week_does() {
        let referrals = store();
        let owner = code_of(&referrals, "owner");
        referrals.redeem("friend", &owner, NOW).expect("redeems");
        let end = NOW + 7 * DAY_SECS;
        assert_eq!(referrals.bonus_seconds("friend", end - 1), 1800);
        assert_eq!(referrals.bonus_seconds("friend", end), 0);
        assert_eq!(referrals.standing("friend", end).unwrap().bonus_ends_at, None);
    }

    #[test]
    fn the_daily_ceiling_refuses_further_redemptions_until_tomorrow() {
        let referrals = store();
        let owner = code_of(&referrals, "owner");
        for n in 0..MAX_REDEMPTIONS_PER_DAY {
            referrals.redeem(&format!("friend-{n}"), &owner, NOW).expect("under the ceiling");
        }
        assert_eq!(referrals.redeem("late", &owner, NOW), Err(ReferralError::Busy));
        assert!(referrals.redeem("late", &owner, NOW + DAY_SECS).is_ok());
    }

    #[test]
    fn codes_and_redemptions_survive_a_restart() {
        let path = scratch("restart");
        let terms = ReferralTerms::default();
        let (first, failure) = Referrals::open(terms, Some(path.clone()));
        assert!(failure.is_none());
        let owner = code_of(&first, "owner");
        first.redeem("friend", &owner, NOW).expect("redeems");
        drop(first);

        let (second, failure) = Referrals::open(terms, Some(path));
        assert!(failure.is_none());
        assert_eq!(code_of(&second, "owner"), owner);
        assert_eq!(second.bonus_seconds("friend", NOW), 1800);
        assert_eq!(second.bonus_seconds("owner", NOW), 1800);
        assert_eq!(second.redeem("friend", &owner, NOW), Err(ReferralError::AlreadyRedeemed));
    }

    #[test]
    fn an_owner_who_earned_keeps_it_when_the_cap_is_lowered_later() {
        let path = scratch("cap");
        let (first, _) = Referrals::open(ReferralTerms::default(), Some(path.clone()));
        let owner = code_of(&first, "owner");
        first.redeem("a", &owner, NOW).expect("redeems");
        first.redeem("b", &owner, NOW).expect("redeems");
        drop(first);

        let lowered = ReferralTerms { max_paid_invites: 1, ..Default::default() };
        let (second, _) = Referrals::open(lowered, Some(path));
        assert_eq!(second.bonus_seconds("owner", NOW), 2 * 1800);
    }

    #[test]
    fn a_torn_line_costs_that_line_only() {
        let path = scratch("torn");
        let (first, _) = Referrals::open(ReferralTerms::default(), Some(path.clone()));
        let owner = code_of(&first, "owner");
        drop(first);
        let mut text = fs::read_to_string(&path).expect("written");
        text.push_str("{\"t\":\"redeem\",\"r\":\"fr");
        fs::write(&path, text).expect("rewritten");

        let (second, failure) = Referrals::open(ReferralTerms::default(), Some(path));
        assert!(failure.is_none());
        assert_eq!(code_of(&second, "owner"), owner);
    }
}
