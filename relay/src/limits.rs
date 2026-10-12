//! Per peer address ceilings, so one address cannot spend the relay's global ones.
//!
//! The global ceilings (`max_connections`, `max_sessions`) bound memory but hand it to whoever
//! asks first: one host could take every signalling slot, and a trickle of allocations against a
//! fake host kept every session alive against the TTL. These bound a single address instead, and
//! are generous because many users share one NAT.
//!
//! IPv6 peers are keyed by their /64, since one subscriber holds a whole one. A loopback peer is
//! exempt by default: behind a reverse proxy every client arrives from 127.0.0.1, and capping that
//! address would cap everyone together.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

/// Entries kept before idle ones are dropped, so the table cannot grow with every address seen.
const PRUNE_ABOVE: usize = 4096;
const RATE_WINDOW: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IpLimits {
    /// Open signalling sockets from one address. `PEERINGD_MAX_SIGNALLING_PER_IP`.
    pub signalling_connections: usize,
    /// Open control sockets from one address, waiting or spliced. `PEERINGD_MAX_CONTROL_PER_IP`.
    pub control_connections: usize,
    /// Sessions one address may allocate per minute. `PEERINGD_SESSIONS_PER_IP_PER_MINUTE`.
    pub sessions_per_minute: u32,
    /// Sessions allocated by one address whose two control ends have not both arrived.
    /// `PEERINGD_MAX_UNSPLICED_PER_IP`.
    pub unspliced_sessions: usize,
    /// Whether a loopback peer is left alone, which is right behind a local reverse proxy.
    pub exempt_loopback: bool,
}

impl Default for IpLimits {
    fn default() -> Self {
        Self {
            signalling_connections: 256,
            control_connections: 512,
            sessions_per_minute: 120,
            unspliced_sessions: 64,
            exempt_loopback: true,
        }
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Signalling,
    Control,
    Unspliced,
}

#[derive(Default)]
struct Tally {
    signalling: usize,
    control: usize,
    unspliced: usize,
    window_started: Option<Instant>,
    allocations: u32,
}

impl Tally {
    fn slot(&mut self, kind: Kind) -> &mut usize {
        match kind {
            Kind::Signalling => &mut self.signalling,
            Kind::Control => &mut self.control,
            Kind::Unspliced => &mut self.unspliced,
        }
    }

    fn idle(&self, now: Instant) -> bool {
        self.signalling == 0
            && self.control == 0
            && self.unspliced == 0
            && self
                .window_started
                .is_none_or(|start| now.saturating_duration_since(start) >= RATE_WINDOW)
    }
}

#[derive(Default)]
pub struct PeerLimiter {
    limits: IpLimits,
    table: Mutex<HashMap<IpAddr, Tally>>,
}

/// Holds one slot against an address and gives it back on drop.
pub struct Permit {
    limiter: Option<Arc<PeerLimiter>>,
    key: Option<IpAddr>,
    kind: Kind,
}

impl Drop for Permit {
    fn drop(&mut self) {
        let (Some(limiter), Some(key)) = (self.limiter.take(), self.key) else { return };
        let mut table = limiter.table.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(tally) = table.get_mut(&key) {
            let slot = tally.slot(self.kind);
            *slot = slot.saturating_sub(1);
            if tally.idle(Instant::now()) {
                table.remove(&key);
            }
        }
    }
}

impl PeerLimiter {
    pub fn new(limits: IpLimits) -> Self {
        Self { limits, table: Mutex::default() }
    }

    fn key(&self, ip: IpAddr) -> Option<IpAddr> {
        let ip = match ip {
            IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
                Some(v4) => IpAddr::V4(v4),
                None => IpAddr::V6(Ipv6Addr::from(u128::from(v6) & (!0u128 << 64))),
            },
            v4 => v4,
        };
        (!(self.limits.exempt_loopback && ip.is_loopback())).then_some(ip)
    }

    fn admit(self: &Arc<Self>, ip: IpAddr, kind: Kind, cap: usize) -> Option<Permit> {
        let Some(key) = self.key(ip) else {
            return Some(Permit { limiter: None, key: None, kind });
        };
        let mut table = self.table.lock().unwrap_or_else(PoisonError::into_inner);
        let slot = table.entry(key).or_default().slot(kind);
        if *slot >= cap {
            return None;
        }
        *slot += 1;
        Some(Permit { limiter: Some(Arc::clone(self)), key: Some(key), kind })
    }

    pub fn admit_signalling(self: &Arc<Self>, ip: IpAddr) -> Option<Permit> {
        self.admit(ip, Kind::Signalling, self.limits.signalling_connections)
    }

    pub fn admit_control(self: &Arc<Self>, ip: IpAddr) -> Option<Permit> {
        self.admit(ip, Kind::Control, self.limits.control_connections)
    }

    /// A slot for a session that lives until both control ends have joined or it is dropped.
    pub fn admit_unspliced(self: &Arc<Self>, ip: IpAddr) -> Option<Permit> {
        self.admit(ip, Kind::Unspliced, self.limits.unspliced_sessions)
    }

    /// Counts one allocation against the address's current minute.
    pub fn allow_allocation(&self, ip: IpAddr) -> bool {
        self.allow_allocation_at(ip, Instant::now())
    }

    fn allow_allocation_at(&self, ip: IpAddr, now: Instant) -> bool {
        let Some(key) = self.key(ip) else { return true };
        let mut table = self.table.lock().unwrap_or_else(PoisonError::into_inner);
        if table.len() > PRUNE_ABOVE {
            table.retain(|_, tally| !tally.idle(now));
        }
        let tally = table.entry(key).or_default();
        match tally.window_started {
            Some(start) if now.saturating_duration_since(start) < RATE_WINDOW => {}
            _ => {
                tally.window_started = Some(now);
                tally.allocations = 0;
            }
        }
        if tally.allocations >= self.limits.sessions_per_minute {
            return false;
        }
        tally.allocations += 1;
        true
    }

    #[cfg(test)]
    fn tracked(&self) -> usize {
        self.table.lock().unwrap_or_else(PoisonError::into_inner).len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limiter(limits: IpLimits) -> Arc<PeerLimiter> {
        Arc::new(PeerLimiter::new(IpLimits { exempt_loopback: false, ..limits }))
    }

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn one_address_cannot_take_more_than_its_share_of_signalling_slots() {
        let limiter = limiter(IpLimits { signalling_connections: 2, ..IpLimits::default() });
        let first = limiter.admit_signalling(ip("203.0.113.5")).unwrap();
        let _second = limiter.admit_signalling(ip("203.0.113.5")).unwrap();
        assert!(limiter.admit_signalling(ip("203.0.113.5")).is_none());
        assert!(limiter.admit_signalling(ip("203.0.113.6")).is_some(), "a neighbour is unaffected");

        drop(first);
        assert!(limiter.admit_signalling(ip("203.0.113.5")).is_some(), "a closed socket frees its slot");
    }

    #[test]
    fn control_and_unspliced_slots_are_counted_separately() {
        let limiter = limiter(IpLimits {
            control_connections: 1,
            unspliced_sessions: 1,
            ..IpLimits::default()
        });
        let _control = limiter.admit_control(ip("198.51.100.1")).unwrap();
        assert!(limiter.admit_control(ip("198.51.100.1")).is_none());
        let _unspliced = limiter.admit_unspliced(ip("198.51.100.1")).unwrap();
        assert!(limiter.admit_unspliced(ip("198.51.100.1")).is_none());
    }

    #[test]
    fn allocation_rate_resets_with_the_window() {
        let limiter = limiter(IpLimits { sessions_per_minute: 3, ..IpLimits::default() });
        let start = Instant::now();
        let address = ip("203.0.113.9");
        assert!((0..3).all(|_| limiter.allow_allocation_at(address, start)));
        assert!(!limiter.allow_allocation_at(address, start + Duration::from_secs(30)));
        assert!(limiter.allow_allocation_at(address, start + RATE_WINDOW));
    }

    #[test]
    fn a_v6_address_is_limited_by_its_prefix_and_a_mapped_one_as_v4() {
        let limiter = limiter(IpLimits { signalling_connections: 1, ..IpLimits::default() });
        let _held = limiter.admit_signalling(ip("2001:db8:1:2::1")).unwrap();
        assert!(limiter.admit_signalling(ip("2001:db8:1:2:ffff::9")).is_none());
        assert!(limiter.admit_signalling(ip("2001:db8:1:3::1")).is_some());

        let _v4 = limiter.admit_signalling(ip("192.0.2.7")).unwrap();
        assert!(limiter.admit_signalling(ip("::ffff:192.0.2.7")).is_none());
    }

    #[test]
    fn loopback_is_exempt_unless_asked_otherwise() {
        let exempt = Arc::new(PeerLimiter::new(IpLimits { signalling_connections: 1, ..IpLimits::default() }));
        let _a = exempt.admit_signalling(ip("127.0.0.1")).unwrap();
        assert!(exempt.admit_signalling(ip("127.0.0.1")).is_some());
        assert_eq!(exempt.tracked(), 0);
    }

    #[test]
    fn idle_addresses_leave_the_table() {
        let limiter = limiter(IpLimits::default());
        drop(limiter.admit_control(ip("203.0.113.1")));
        assert_eq!(limiter.tracked(), 0);
    }
}
