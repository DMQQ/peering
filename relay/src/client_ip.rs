//! Which header names the real client when a reverse proxy on this machine fronts the relay.
//!
//! Only one header is ever read, and only on a loopback connection. nginx overwrites `X-Real-IP`
//! with the true connection address, while it passes a client's own `CF-Connecting-IP` and appends
//! to a client's own `X-Forwarded-For`, so those two are forgeable unless the front end is known to
//! scrub them.

use std::net::{IpAddr, SocketAddr};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ClientIpHeader {
    #[default]
    XRealIp,
    CfConnectingIp,
    XForwardedFor,
}

impl ClientIpHeader {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "x-real-ip" => Some(Self::XRealIp),
            "cf-connecting-ip" => Some(Self::CfConnectingIp),
            "x-forwarded-for" => Some(Self::XForwardedFor),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::XRealIp => "x-real-ip",
            Self::CfConnectingIp => "cf-connecting-ip",
            Self::XForwardedFor => "x-forwarded-for",
        }
    }

    /// The right-most valid `X-Forwarded-For` entry is the one the local proxy appended.
    fn read(self, headers: &http::HeaderMap) -> Option<IpAddr> {
        let value = headers.get(self.name())?.to_str().ok()?;
        match self {
            Self::XForwardedFor => value.rsplit(',').find_map(parse_address),
            _ => parse_address(value),
        }
    }
}

/// Parses an address as a proxy writes it: bare, with a port, or a bracketed IPv6 literal.
fn parse_address(raw: &str) -> Option<IpAddr> {
    let raw = raw.trim();
    raw.parse::<IpAddr>()
        .ok()
        .or_else(|| raw.parse::<SocketAddr>().ok().map(|address| address.ip()))
        .or_else(|| raw.strip_prefix('[')?.strip_suffix(']')?.parse().ok())
}

pub fn is_loopback(peer: IpAddr) -> bool {
    match peer {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(peer, IpAddr::V4).is_loopback(),
        v4 => v4.is_loopback(),
    }
}

/// The client address a loopback proxy reports in `header`. A peer that is not loopback is a direct
/// client and is never allowed to name another address.
pub fn forwarded_address(peer: IpAddr, headers: &http::HeaderMap, header: ClientIpHeader) -> Option<IpAddr> {
    is_loopback(peer).then(|| header.read(headers)).flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(pairs: &[(&str, &str)]) -> http::HeaderMap {
        let mut map = http::HeaderMap::new();
        for (name, value) in pairs {
            map.append(
                http::HeaderName::from_bytes(name.as_bytes()).expect("name"),
                http::HeaderValue::from_str(value).expect("value"),
            );
        }
        map
    }

    fn loopback() -> IpAddr {
        "127.0.0.1".parse().expect("address")
    }

    #[test]
    fn a_forged_cf_connecting_ip_and_forwarded_for_are_ignored_by_default() {
        let forged = headers(&[("cf-connecting-ip", "6.6.6.6"), ("x-forwarded-for", "7.7.7.7, 8.8.8.8")]);
        assert_eq!(forwarded_address(loopback(), &forged, ClientIpHeader::default()), None);
    }

    #[test]
    fn x_real_ip_is_honoured_and_beats_forged_headers_beside_it() {
        let both = headers(&[("x-real-ip", "203.0.113.9"), ("cf-connecting-ip", "6.6.6.6")]);
        assert_eq!(
            forwarded_address(loopback(), &both, ClientIpHeader::default()),
            Some("203.0.113.9".parse().expect("address"))
        );
    }

    #[test]
    fn a_configured_header_is_the_one_read() {
        let both = headers(&[("x-real-ip", "203.0.113.9"), ("cf-connecting-ip", "198.51.100.4")]);
        assert_eq!(
            forwarded_address(loopback(), &both, ClientIpHeader::CfConnectingIp),
            Some("198.51.100.4".parse().expect("address"))
        );
    }

    #[test]
    fn a_configured_forwarded_for_takes_the_entry_the_proxy_appended() {
        let chain = headers(&[("x-forwarded-for", "6.6.6.6, 203.0.113.9")]);
        assert_eq!(
            forwarded_address(loopback(), &chain, ClientIpHeader::XForwardedFor),
            Some("203.0.113.9".parse().expect("address"))
        );
    }

    #[test]
    fn garbage_in_the_trusted_header_is_ignored() {
        for value in ["not an address", "", "999.1.1.1", "1.2.3"] {
            assert_eq!(forwarded_address(loopback(), &headers(&[("x-real-ip", value)]), ClientIpHeader::XRealIp), None);
        }
    }

    #[test]
    fn a_direct_client_cannot_name_another_address() {
        let direct: IpAddr = "203.0.113.50".parse().expect("address");
        let forged = headers(&[("x-real-ip", "6.6.6.6")]);
        assert_eq!(forwarded_address(direct, &forged, ClientIpHeader::XRealIp), None);
    }

    #[test]
    fn bracketed_and_ported_addresses_parse() {
        let bracketed = headers(&[("x-real-ip", "[2001:db8::1]")]);
        assert_eq!(
            forwarded_address(loopback(), &bracketed, ClientIpHeader::XRealIp),
            Some("2001:db8::1".parse().expect("address"))
        );
        let ported = headers(&[("x-real-ip", "203.0.113.9:5555")]);
        assert_eq!(
            forwarded_address(loopback(), &ported, ClientIpHeader::XRealIp),
            Some("203.0.113.9".parse().expect("address"))
        );
    }

    #[test]
    fn only_the_three_known_header_names_parse() {
        assert_eq!(ClientIpHeader::parse("X-Real-IP"), Some(ClientIpHeader::XRealIp));
        assert_eq!(ClientIpHeader::parse("CF-Connecting-IP"), Some(ClientIpHeader::CfConnectingIp));
        assert_eq!(ClientIpHeader::parse("X-Forwarded-For"), Some(ClientIpHeader::XForwardedFor));
        assert_eq!(ClientIpHeader::parse("True-Client-IP"), None);
    }
}
