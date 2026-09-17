//! Where the relay listens, and how long it holds a session open.

use std::collections::HashSet;
use std::env;
use std::fmt;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

/// Runtime configuration, read from the environment.
///
/// The defaults are chosen so that running `peeringd` with no configuration at all gives a working
/// relay on the local machine — which is what the loopback test needs, and what makes the whole
/// thing debuggable without a VPS in the loop.
#[derive(Debug, Clone)]
pub struct Config {
    /// Signalling: hosts and clients register here and are introduced to each other.
    pub signal_addr: SocketAddr,
    /// Control relay: two connections per session, spliced.
    pub control_addr: SocketAddr,
    /// Video relay: the address to bind per-session UDP sockets on. Port 0 means the OS picks, and
    /// the port is reported back to the two ends — which is what we want, since a session's port
    /// has to be unique.
    pub video_bind: SocketAddr,
    /// The range session video ports are drawn from, if one is configured.
    ///
    /// **Worth setting on anything with a firewall.** With no range the OS chooses from the whole
    /// ephemeral range — 32768 to 60999 on a default Linux — so allowing video through means
    /// opening twenty-eight thousand UDP ports. A range of a hundred turns that into one rule.
    /// Video failing while control works is what a closed range looks like, and it is a miserable
    /// thing to debug, so it is better to say which ports will be used and let them be opened.
    pub video_ports: Option<PortRange>,
    /// The control port **as clients must reach it**, when that differs from the port the relay
    /// binds.
    ///
    /// This is the shared-IPv4 case: a host forwards one of its own ports on a shared address to a
    /// port of yours, and the two numbers need not match. Clients can only reach the outside one,
    /// so that is the one to hand them.
    pub public_control_port: Option<u16>,
    /// The video port as clients must reach it, for the same reason. Only meaningful with a
    /// single-port [`Self::video_ports`] range — a range is a different port per session, and there
    /// is no way to express a per-session mapping on a shared address.
    pub public_video_port: Option<u16>,
    /// The address to tell clients to connect back to, when it differs from the address they
    /// reached us on.
    ///
    /// **Required behind any proxy.** The relay otherwise reports the local address of the accepted
    /// socket as the place to connect for control and video — which is exactly right when clients
    /// address it directly, and exactly wrong when they come through nginx, where that address is
    /// `127.0.0.1` and every client would be told to connect to itself.
    pub public_host: Option<String>,
    /// TLS for the signalling listener. `None` serves plaintext, which is only appropriate for
    /// loopback; the two ends' own traffic is encrypted end-to-end regardless.
    pub tls: Option<TlsFiles>,
    /// How long a session survives without activity. A session is created when a phone asks for a
    /// Mac and lives until both connections have been made and then dropped, or until this elapses
    /// and it is swept.
    pub session_ttl: Duration,
    /// Free relay minutes per client per 30-day window. Set to 0 to disable relay for free clients
    /// entirely.
    pub free_minutes: u64,
    /// API keys that grant unlimited relay access, loaded from `PEERINGD_PAID_KEYS` as a
    /// comma-separated list. Each key is an opaque string the client presents in `ConnectToHost`.
    pub paid_keys: HashSet<String>,
}

#[derive(Debug, Clone)]
pub struct TlsFiles {
    pub cert: PathBuf,
    pub key: PathBuf,
}

/// An inclusive range of ports, written `40000-40100`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PortRange {
    pub first: u16,
    pub last: u16,
}

impl PortRange {
    pub fn parse(text: &str) -> Option<Self> {
        let (first, last) = text.split_once('-')?;
        let first: u16 = first.trim().parse().ok()?;
        let last: u16 = last.trim().parse().ok()?;

        // Port 0 is excluded deliberately: it means "let the OS choose", which is the opposite of
        // what someone configuring a fixed range is asking for.
        (first > 0 && first <= last).then_some(Self { first, last })
    }

    pub fn len(&self) -> usize {
        usize::from(self.last - self.first) + 1
    }

    pub fn is_empty(&self) -> bool {
        false // A range that parsed always holds at least one port.
    }

    pub fn iter(&self) -> impl Iterator<Item = u16> {
        self.first..=self.last
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ConfigError {
    BadAddress(&'static str, String),
    BadDuration(&'static str, String),
    /// A certificate without its key, or a key without its certificate.
    HalfATlsPair(&'static str),
    BadPortRange(String),
    BadPort(&'static str, String),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadAddress(name, value) => write!(f, "{name} is not a valid address: {value:?}"),
            Self::BadDuration(name, value) => {
                write!(f, "{name} is not a whole number of seconds: {value:?}")
            }
            Self::HalfATlsPair(missing) => {
                write!(f, "{missing} is set but its partner is not; TLS needs both")
            }
            Self::BadPortRange(value) => {
                write!(f, "PEERINGD_VIDEO_PORTS is not a range like 40000-40100: {value:?}")
            }
            Self::BadPort(name, value) => {
                write!(f, "{name} is not a port number between 1 and 65535: {value:?}")
            }
        }
    }
}

impl std::error::Error for ConfigError {}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(|name| env::var(name).ok())
    }

    /// Reads configuration from anywhere, not just the process environment.
    ///
    /// The indirection exists for the tests, and it is worth the small cost here. The obvious
    /// alternative — setting and clearing real environment variables from tests — is what edition
    /// 2024 made `unsafe`, and correctly so: the process environment is global, Rust runs tests on
    /// parallel threads, and a test mutating it while another reads it is a data race, not a
    /// theoretical one. Taking a lookup means the tests touch nothing shared.
    pub fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        // An empty value counts as unset, so `PEERINGD_TLS_CERT= peeringd` behaves the way someone
        // clearing a variable expects it to.
        let get = |name: &str| lookup(name).filter(|value| !value.is_empty());

        let tls = match (
            get("PEERINGD_TLS_CERT").map(PathBuf::from),
            get("PEERINGD_TLS_KEY").map(PathBuf::from),
        ) {
            (Some(cert), Some(key)) => Some(TlsFiles { cert, key }),
            (None, None) => None,
            (Some(_), None) => return Err(ConfigError::HalfATlsPair("PEERINGD_TLS_CERT")),
            (None, Some(_)) => return Err(ConfigError::HalfATlsPair("PEERINGD_TLS_KEY")),
        };

        let video_ports = match get("PEERINGD_VIDEO_PORTS") {
            None => None,
            Some(raw) => match PortRange::parse(&raw) {
                Some(range) => Some(range),
                None => return Err(ConfigError::BadPortRange(raw)),
            },
        };

        let paid_keys = get("PEERINGD_PAID_KEYS")
            .map(|raw| raw.split(',').map(|k| k.trim().to_string()).filter(|k| !k.is_empty()).collect())
            .unwrap_or_default();

        Ok(Self {
            signal_addr: address(&get, "PEERINGD_SIGNAL_ADDR", "0.0.0.0:8443")?,
            control_addr: address(&get, "PEERINGD_CONTROL_ADDR", "0.0.0.0:9443")?,
            video_bind: address(&get, "PEERINGD_VIDEO_BIND", "0.0.0.0:0")?,
            video_ports,
            public_control_port: optional_port(&get, "PEERINGD_PUBLIC_CONTROL_PORT")?,
            public_video_port: optional_port(&get, "PEERINGD_PUBLIC_VIDEO_PORT")?,
            public_host: get("PEERINGD_PUBLIC_HOST"),
            tls,
            session_ttl: Duration::from_secs(seconds(&get, "PEERINGD_SESSION_TTL", 300)?),
            free_minutes: seconds(&get, "PEERINGD_FREE_MINUTES", 15)?,
            paid_keys,
        })
    }
}

type Lookup<'a> = &'a dyn Fn(&str) -> Option<String>;

fn address(
    get: Lookup<'_>,
    name: &'static str,
    default: &str,
) -> Result<SocketAddr, ConfigError> {
    let raw = get(name).unwrap_or_else(|| default.to_string());
    raw.parse()
        .map_err(|_| ConfigError::BadAddress(name, raw.clone()))
}

/// A port that is unset by default, and rejected rather than defaulted when it is nonsense. Port 0
/// is refused because it means "let the OS choose" on a bind and "nowhere" as something to tell a
/// client to connect to.
fn optional_port(get: Lookup<'_>, name: &'static str) -> Result<Option<u16>, ConfigError> {
    match get(name) {
        None => Ok(None),
        Some(raw) => match raw.parse::<u16>() {
            Ok(port) if port > 0 => Ok(Some(port)),
            _ => Err(ConfigError::BadPort(name, raw)),
        },
    }
}

fn seconds(get: Lookup<'_>, name: &'static str, default: u64) -> Result<u64, ConfigError> {
    match get(name) {
        None => Ok(default),
        Some(raw) => raw
            .parse()
            .map_err(|_| ConfigError::BadDuration(name, raw.clone())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn configured(pairs: &[(&str, &str)]) -> Result<Config, ConfigError> {
        let values: HashMap<String, String> = pairs
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect();
        Config::from_lookup(|name| values.get(name).cloned())
    }

    /// The defaults are what the loopback test depends on, so they are worth pinning down.
    #[test]
    fn nothing_configured_is_a_working_local_relay() {
        let config = configured(&[]).expect("defaults should parse");

        assert_eq!(config.signal_addr.port(), 8443);
        assert_eq!(config.control_addr.port(), 9443);
        assert_eq!(
            config.video_bind.port(),
            0,
            "a session's port must be pickable"
        );
        assert!(config.tls.is_none());
        assert_eq!(config.session_ttl, Duration::from_secs(300));
    }

    #[test]
    fn a_certificate_without_a_key_is_refused() {
        assert!(matches!(
            configured(&[("PEERINGD_TLS_CERT", "/tmp/relay.pem")]),
            Err(ConfigError::HalfATlsPair("PEERINGD_TLS_CERT"))
        ));
        assert!(matches!(
            configured(&[("PEERINGD_TLS_KEY", "/tmp/relay.key")]),
            Err(ConfigError::HalfATlsPair("PEERINGD_TLS_KEY"))
        ));
    }

    #[test]
    fn a_complete_tls_pair_is_accepted_and_an_empty_one_is_not_tls_at_all() {
        let config = configured(&[
            ("PEERINGD_TLS_CERT", "/tmp/relay.pem"),
            ("PEERINGD_TLS_KEY", "/tmp/relay.key"),
        ])
        .expect("a complete pair should parse");
        assert!(config.tls.is_some());

        // How someone clears a variable, and it should mean "off" rather than "a TLS pair whose
        // paths are empty strings".
        let config = configured(&[
            ("PEERINGD_TLS_CERT", ""),
            ("PEERINGD_TLS_KEY", "/tmp/relay.key"),
        ]);
        assert!(matches!(
            config,
            Err(ConfigError::HalfATlsPair("PEERINGD_TLS_KEY"))
        ));
    }

    #[test]
    fn a_malformed_address_is_reported_with_the_value_that_was_wrong() {
        let error = configured(&[("PEERINGD_SIGNAL_ADDR", "not-an-address")]).unwrap_err();
        assert_eq!(
            error,
            ConfigError::BadAddress("PEERINGD_SIGNAL_ADDR", "not-an-address".to_string())
        );
    }

    #[test]
    fn the_session_lifetime_is_configurable() {
        let config = configured(&[("PEERINGD_SESSION_TTL", "45")]).unwrap();
        assert_eq!(config.session_ttl, Duration::from_secs(45));

        assert!(matches!(
            configured(&[("PEERINGD_SESSION_TTL", "soon")]),
            Err(ConfigError::BadDuration(_, _))
        ));
    }

    #[test]
    fn a_public_host_is_optional_until_a_proxy_is_in_front() {
        assert!(configured(&[]).unwrap().public_host.is_none());

        let config = configured(&[("PEERINGD_PUBLIC_HOST", "peering.dmqq.dev")]).unwrap();
        assert_eq!(config.public_host.as_deref(), Some("peering.dmqq.dev"));
    }

    #[test]
    fn public_ports_are_optional_and_nonsense_is_refused() {
        let config = configured(&[]).unwrap();
        assert!(config.public_control_port.is_none());
        assert!(config.public_video_port.is_none());

        let config = configured(&[
            ("PEERINGD_PUBLIC_CONTROL_PORT", "51234"),
            ("PEERINGD_PUBLIC_VIDEO_PORT", "51235"),
        ])
        .unwrap();
        assert_eq!(config.public_control_port, Some(51234));
        assert_eq!(config.public_video_port, Some(51235));

        // Port 0 is refused rather than accepted: it is meaningful on a bind, meaning "choose one",
        // and meaningless as something to hand a client to connect to.
        for bad in ["0", "70000", "abc", "-1"] {
            assert!(
                matches!(
                    configured(&[("PEERINGD_PUBLIC_CONTROL_PORT", bad)]),
                    Err(ConfigError::BadPort(_, _))
                ),
                "{bad:?} should be refused as a public port"
            );
        }
    }

    #[test]
    fn no_video_range_configured_means_the_os_chooses() {
        let config = configured(&[]).unwrap();
        assert!(config.video_ports.is_none());
    }

    #[test]
    fn a_video_range_is_parsed_inclusively() {
        let config = configured(&[("PEERINGD_VIDEO_PORTS", "40000-40100")]).unwrap();
        let range = config.video_ports.expect("should have parsed");

        assert_eq!(range.first, 40000);
        assert_eq!(range.last, 40100);
        assert_eq!(range.len(), 101, "both ends are included");
        assert_eq!(range.iter().count(), 101);
        assert_eq!(range.iter().next(), Some(40000));
        assert_eq!(range.iter().last(), Some(40100));
    }

    #[test]
    fn a_single_port_range_is_allowed() {
        let range = PortRange::parse("40000-40000").expect("should parse");
        assert_eq!(range.len(), 1);
    }

    #[test]
    fn a_nonsense_video_range_is_refused() {
        for bad in ["", "40000", "40100-40000", "0-10", "abc-def", "40000-", "-40100", "70000-70001"] {
            assert!(
                PortRange::parse(bad).is_none(),
                "{bad:?} should not parse as a range"
            );
        }

        // And through the config, so the error is reported rather than silently ignored.
        assert!(matches!(
            configured(&[("PEERINGD_VIDEO_PORTS", "40100-40000")]),
            Err(ConfigError::BadPortRange(_))
        ));
    }
}
