//! Who may hold a pre-authentication slot. A global cap alone lets one LAN host fill it, so each address also has a share.

use std::collections::BTreeMap;
use std::net::IpAddr;

/// The most pre-authentication connections one address (or one IPv6 network) may hold at once.
pub const PER_ADDRESS_LIMIT: usize = 4;

/// Whose connection this is, for counting. An IPv4 address stands for itself, an IPv4 address inside an IPv6 one is read
/// as the IPv4 address, and an IPv6 address stands for its /64, because one machine owns a whole /64 of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct AddressKey(u128);

impl AddressKey {
    pub fn of(address: IpAddr) -> Self {
        match address.to_canonical() {
            IpAddr::V4(v4) => Self(u128::from(u32::from(v4))),
            IpAddr::V6(v6) => Self(((u128::from(v6) >> 64) << 64) | (1u128 << 63)),
        }
    }
}

/// Counts what each key holds and refuses a key past its limit.
#[derive(Debug)]
pub struct PerKeyLimit<K: Ord + Copy> {
    limit: usize,
    held: BTreeMap<K, usize>,
}

impl<K: Ord + Copy> PerKeyLimit<K> {
    pub fn new(limit: usize) -> Self {
        Self { limit, held: BTreeMap::new() }
    }

    /// Takes a share for `key`, or returns false when it already holds its limit.
    pub fn enter(&mut self, key: K) -> bool {
        let count = self.held.entry(key).or_insert(0);
        if *count >= self.limit {
            return false;
        }
        *count += 1;
        true
    }

    /// Gives a share back. A key with nothing held is forgotten, so the map does not grow with every address seen.
    pub fn leave(&mut self, key: K) {
        if let Some(count) = self.held.get_mut(&key) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.held.remove(&key);
            }
        }
    }

    pub fn holding(&self, key: K) -> usize {
        self.held.get(&key).copied().unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v4(text: &str) -> AddressKey {
        AddressKey::of(text.parse().expect("an address"))
    }

    #[test]
    fn one_address_is_refused_past_its_share() {
        let mut limit = PerKeyLimit::new(PER_ADDRESS_LIMIT);
        let key = v4("192.168.1.20");
        for _ in 0..PER_ADDRESS_LIMIT {
            assert!(limit.enter(key));
        }
        assert!(!limit.enter(key));
    }

    #[test]
    fn another_address_is_not_affected_by_a_full_one() {
        let mut limit = PerKeyLimit::new(1);
        assert!(limit.enter(v4("192.168.1.20")));
        assert!(!limit.enter(v4("192.168.1.20")));
        assert!(limit.enter(v4("192.168.1.21")));
    }

    #[test]
    fn leaving_frees_a_share_and_forgets_an_empty_key() {
        let mut limit = PerKeyLimit::new(1);
        let key = v4("10.0.0.5");
        assert!(limit.enter(key));
        limit.leave(key);
        assert_eq!(limit.holding(key), 0);
        assert!(limit.enter(key));
    }

    #[test]
    fn leaving_a_key_that_holds_nothing_changes_nothing() {
        let mut limit: PerKeyLimit<AddressKey> = PerKeyLimit::new(1);
        limit.leave(v4("10.0.0.5"));
        assert!(limit.enter(v4("10.0.0.5")));
    }

    #[test]
    fn an_ipv4_address_inside_an_ipv6_one_counts_as_the_ipv4_address() {
        assert_eq!(v4("::ffff:192.168.1.20"), v4("192.168.1.20"));
    }

    #[test]
    fn addresses_in_one_ipv6_network_share_a_key() {
        assert_eq!(v4("fe80::1"), v4("fe80::2:3:4:5"));
        assert_ne!(v4("fe80::1"), v4("fe80:0:0:1::1"));
    }

    #[test]
    fn an_ipv6_network_never_collides_with_an_ipv4_address() {
        assert_ne!(v4("0.0.0.1"), v4("::1"));
        assert_ne!(v4("192.168.1.20"), v4("c0a8:0114::"));
    }
}
