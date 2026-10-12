//! Where one datagram of the relayed lane goes, and what it looks like when it gets there. The relay needs the 16 byte token
//! in front of every datagram it forwards. A direct peer reads the counter from the first byte, because the token only exists
//! to name a session to the relay.

use std::net::SocketAddr;

const TOKEN_LENGTH: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Path {
    Relay,
    Direct(SocketAddr),
}

/// The path a datagram arrived on: from the relay's address it came through the relay, from anywhere else it is direct.
pub fn arrival_path(source: SocketAddr, relay: SocketAddr) -> Path {
    if source == relay {
        Path::Relay
    } else {
        Path::Direct(source)
    }
}

/// The address to send to and the bytes to send, or None when a direct datagram is too short to hold its token.
pub fn route(path: Path, relay: SocketAddr, datagram: &[u8]) -> Option<(SocketAddr, &[u8])> {
    match path {
        Path::Relay => Some((relay, datagram)),
        Path::Direct(peer) => datagram.get(TOKEN_LENGTH..).map(|bytes| (peer, bytes)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn address(text: &str) -> SocketAddr {
        text.parse().expect("a socket address")
    }

    #[test]
    fn a_datagram_from_the_relays_address_arrived_through_the_relay() {
        let relay = address("192.0.2.10:4000");
        assert_eq!(arrival_path(relay, relay), Path::Relay);
        assert_eq!(arrival_path(address("192.0.2.11:4000"), relay), Path::Direct(address("192.0.2.11:4000")));
    }

    #[test]
    fn a_relayed_datagram_keeps_its_token() {
        let relay = address("192.0.2.10:4000");
        let datagram = [7u8; 20];
        assert_eq!(route(Path::Relay, relay, &datagram), Some((relay, &datagram[..])));
    }

    #[test]
    fn a_direct_datagram_drops_the_token_in_front() {
        let relay = address("192.0.2.10:4000");
        let peer = address("198.51.100.9:5000");
        let mut datagram = vec![7u8; 16];
        datagram.extend_from_slice(&[1, 2, 3]);
        assert_eq!(route(Path::Direct(peer), relay, &datagram), Some((peer, &[1u8, 2, 3][..])));
    }

    #[test]
    fn a_direct_datagram_without_a_whole_token_is_not_sent() {
        let relay = address("192.0.2.10:4000");
        let peer = address("198.51.100.9:5000");
        assert_eq!(route(Path::Direct(peer), relay, &[0u8; 15]), None);
    }
}
