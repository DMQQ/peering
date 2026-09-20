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
    /// Video relay: the address the relay's **one** UDP socket is bound on, at startup.
    ///
    /// Port 0 means the OS picks, and the port is reported to every session in its `ready` message —
    /// which is only workable because there is exactly one of them. This is the port a firewall
    /// rule has to open, and the whole point of the shared socket: a host forwarding a small number
    /// of ports on a shared address forwards this one, and every session with video uses it.
    pub video_bind: SocketAddr,
    /// `PEERINGD_VIDEO_PORTS` as it was found, if it was found at all.
    ///
    /// **Read, and deliberately not parsed.** It named the range session video ports were drawn
    /// from, and sessions no longer have ports of their own, so there is no range to name — but an
    /// existing deployment has this line in its environment and a relay that refused to start over
    /// it would be a relay that goes down on the next deploy. Kept only so startup can say, loudly,
    /// that it is doing nothing. `main` is where that warning is written; nothing here interprets
    /// the value, and a typo in it is no longer an error because nothing depends on it.
    pub stale_video_ports: Option<String>,
    /// The control port **as clients must reach it**, when that differs from the port the relay
    /// binds.
    ///
    /// This is the shared-IPv4 case: a host forwards one of its own ports on a shared address to a
    /// port of yours, and the two numbers need not match. Clients can only reach the outside one,
    /// so that is the one to hand them.
    pub public_control_port: Option<u16>,
    /// The video port as clients must reach it, for the same reason.
    ///
    /// Unlike the control port this cannot be read off the bound socket at all, because the
    /// forwarded port is the host's to choose and need not match. It now applies to every session
    /// at once, which is what makes the shared address workable: one number to forward, one number
    /// to tell every client, instead of a range whose ports could not be forwarded individually.
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
    /// How much relay time each plan is allowed, per window.
    pub plans: PlanAllowances,
    /// API keys that grant unlimited relay access, loaded from `PEERINGD_PAID_KEYS` as a
    /// comma-separated list. Each key is an opaque string the client presents in `ConnectToHost`.
    ///
    /// **This is the second grant the relay does not take the client's word for**, the first being
    /// the receipt on `ConnectToHost` and the plan it proves — see `storekit`. It is kept even
    /// though nothing mints a key that could be in it, because it costs nothing and it is the only
    /// way to grant one machine unlimited relay without a purchase.
    pub paid_keys: HashSet<String>,
    /// Whether a plan the client claims is believed when it sends no receipt, or one that does not
    /// verify. `PEERINGD_TRUST_CLAIMED_PLANS`, **false by default**.
    ///
    /// **Closed, because a claim is not evidence.** A client that sends `"plan":"pro"` and nothing
    /// to back it up is metered as free, which is the only reading of an unproven plan that does
    /// not hand out unlimited relay for a string. The app proves what it bought with the JWS
    /// StoreKit hands it, so the receipt path is open to everyone who has actually bought
    /// something, and an unproven claim is what is left when nobody did.
    ///
    /// **Setting it true is for beta testing, and it re-opens the whole hole.** A TestFlight
    /// build's receipt is a sandbox one, which `storekit` refuses by name: Apple signs those, they
    /// name the real products, and anyone with a developer account can mint one for nothing, so
    /// they are not evidence that anybody paid. With this closed a tester is metered as free, half
    /// an hour a day on a build that says it is on `pro`; an operator running a beta sets this true
    /// so that the testers are metered by what they claim, and every other client gets its plan
    /// from the same switch for as long as it is on.
    pub trust_claimed_plans: bool,
    /// Where the marketing site is served.
    ///
    /// **Loopback by default**, and deliberately. The site is meant to sit behind whatever already
    /// terminates TLS on the machine — nginx, Caddy, Cloudflare — and a listener that is
    /// accidentally public is a worse mistake than one that is accidentally private.
    pub web_addr: SocketAddr,
    /// The directory the site is read from.
    ///
    /// Relative paths resolve against the working directory, which is what makes `cargo run` in
    /// this crate serve the copy in `site/` with no configuration at all. A directory that is not
    /// there is not an error: the relay says so and carries on without a site.
    pub web_root: PathBuf,
    /// Where the relay-time counter is written down. `PEERINGD_USAGE_LOG`.
    ///
    /// **Unset is the default, and it is the safe default rather than the lazy one.** A default
    /// path would have to be somewhere the service can write, and the unit this ships with grants
    /// it no writable path at all, so the choice would be between a relay that starts and records
    /// nothing and a relay that refuses to start. Neither is a good default. Set this to a file
    /// inside a state directory the service owns, and startup will say whether it took; leave it
    /// unset and startup will say, just as plainly, that a restart resets every counter.
    pub usage_log: Option<PathBuf>,
    /// Where the device-to-public-key bindings are written. `PEERINGD_DEVICE_BINDINGS`.
    ///
    /// **Unset means the relay forgets them on restart**, and that is a real weakening rather than
    /// a neutral default: a binding is what lets a registration that cannot sign for a device ID be
    /// refused, so a relay that forgets re-opens the window for every ID it had learned. It is not
    /// an *opening* of the hole, because the memory-only behaviour is still strictly better than
    /// having no binding at all for the length of a run. Set it, in the same state directory as the
    /// usage log. See `device_bindings.rs`.
    pub device_bindings: Option<PathBuf>,
    /// How many sessions may exist at once, over the whole process.
    /// `PEERINGD_MAX_SESSIONS`, 1000 by default.
    ///
    /// **A ceiling that exists to bound an attack, not to shape normal use.** A session is created
    /// by anyone who can open a signalling connection and name a Mac: there is no cost to asking
    /// and no authentication in front of it, so a loop that varies the client id creates a session
    /// per message until the box runs out of memory. Every real session on a box with a shared
    /// gigabit uplink costs about a megabit, so a thousand of them is already several times what
    /// this machine could carry, and the number is here to make the failure a refusal rather than
    /// an OOM kill. Raise it on a bigger link; the memory per session is small.
    pub max_sessions: usize,
    /// How many sockets may be open on the signalling listener at once.
    /// `PEERINGD_MAX_CONNECTIONS`, 4096 by default.
    ///
    /// The other half of the same defence, and it has to be larger than the count of registered
    /// Macs: a Mac holds its registration socket open for as long as it is running, so this is
    /// "every Mac that could be online, plus everyone connecting right now". A connection beyond
    /// it is closed immediately rather than queued, which is the behaviour that keeps an attack
    /// from turning into a backlog of work.
    pub max_connections: usize,
    /// How long a socket may take to become a WebSocket, and how long it may then sit silent.
    /// `PEERINGD_SIGNALLING_TIMEOUTS`, `10s,90s` by default.
    ///
    /// Two numbers because they answer two different questions. The first bounds a connection that
    /// has not finished saying hello: without it, a socket that sends nothing holds a task and a
    /// file descriptor for as long as it likes, at any stage of the TLS handshake. The second
    /// bounds one that has said hello and then gone quiet, and it has to be comfortably longer than
    /// the host's own keepalive: a registered Mac pings every 25 seconds, so 90 is three missed
    /// pings rather than a hiccup.
    pub handshake_timeout: Duration,
    pub idle_timeout: Duration,
}

/// Sessions at once, unless `PEERINGD_MAX_SESSIONS` says otherwise. See the field for why 1000.
const DEFAULT_MAX_SESSIONS: usize = 1000;
/// Signalling sockets at once, unless `PEERINGD_MAX_CONNECTIONS` says otherwise.
const DEFAULT_MAX_CONNECTIONS: usize = 4096;
/// Seconds a socket has to finish saying hello, and to keep saying something. See the fields.
const DEFAULT_HANDSHAKE_SECONDS: u64 = 10;
const DEFAULT_IDLE_SECONDS: u64 = 90;

/// Free relay minutes per client per window, unless `PEERINGD_FREE_MINUTES` says otherwise.
///
/// **Fifteen rather than thirty, and the reason is what free is for.** Free's own promise, on the
/// site and in the app, is "your own network, for as long as you like": the direct path is
/// unlimited on every plan and costs nothing to serve, and the relay allowance is there to answer
/// "does this work when I am out". Half an hour a day answered that and then kept answering it, so
/// a free user with a commute spent the whole allowance every day without ever reaching a wall
/// they would pay to remove. Fifteen still covers a first proper try and runs out in the middle of
/// regular use, which is the difference between a sample and a subscription.
const DEFAULT_FREE_MINUTES: u64 = 15;
/// Relay-plan minutes per client per window, unless `PEERINGD_RELAY_MINUTES` says otherwise.
const DEFAULT_RELAY_MINUTES: u64 = 180;

/// What each plan is allowed, in seconds per window.
///
/// The two numbers here are the whole of the product's promise about relay time: fifteen minutes a
/// day free, three hours a day on the cheapest subscription, and no limit above that. They are
/// configurable because an operator may want to be stingier or more generous than the app's copy
/// says, and the app's copy is what has to keep up — `SessionHistory.swift` mirrors these numbers
/// to draw its "free relay time" bar, or the bar lies.
///
/// Zero is allowed and means what it says: `PEERINGD_FREE_MINUTES=0` blocks relay for free clients
/// entirely rather than making it unlimited. There is deliberately no spelling for "unlimited"
/// here. An operator who wants to give a plan away for nothing has set the price of the product,
/// not configured the relay.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlanAllowances {
    /// `PEERINGD_FREE_MINUTES`, 15 by default. `None` would mean unlimited; nothing sets it.
    pub free_seconds: Option<u64>,
    /// `PEERINGD_RELAY_MINUTES`, 180 by default.
    pub relay_seconds: Option<u64>,
}

impl Default for PlanAllowances {
    fn default() -> Self {
        Self {
            free_seconds: Some(DEFAULT_FREE_MINUTES * 60),
            relay_seconds: Some(DEFAULT_RELAY_MINUTES * 60),
        }
    }
}

#[derive(Debug, Clone)]
pub struct TlsFiles {
    pub cert: PathBuf,
    pub key: PathBuf,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ConfigError {
    BadAddress(&'static str, String),
    BadDuration(&'static str, String),
    /// A certificate without its key, or a key without its certificate.
    HalfATlsPair(&'static str),
    BadPort(&'static str, String),
    /// A switch that is not one of the spellings of yes and no.
    NotABoolean(&'static str, String),
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
            Self::BadPort(name, value) => {
                write!(f, "{name} is not a port number between 1 and 65535: {value:?}")
            }
            Self::NotABoolean(name, value) => {
                write!(f, "{name} is not a switch like 0, 1, true or false: {value:?}")
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

        // Not parsed, not validated, not used — see the field. The raw value is carried out of here
        // only so that startup can name what it is ignoring, which is the difference between an
        // operator who knows their old range is dead and one who believes it is still opening ports.
        let stale_video_ports = get("PEERINGD_VIDEO_PORTS");

        let paid_keys = get("PEERINGD_PAID_KEYS")
            .map(|raw| raw.split(',').map(|k| k.trim().to_string()).filter(|k| !k.is_empty()).collect())
            .unwrap_or_default();

        Ok(Self {
            signal_addr: address(&get, "PEERINGD_SIGNAL_ADDR", "0.0.0.0:8443")?,
            control_addr: address(&get, "PEERINGD_CONTROL_ADDR", "0.0.0.0:9443")?,
            video_bind: address(&get, "PEERINGD_VIDEO_BIND", "0.0.0.0:0")?,
            stale_video_ports,
            public_control_port: optional_port(&get, "PEERINGD_PUBLIC_CONTROL_PORT")?,
            public_video_port: optional_port(&get, "PEERINGD_PUBLIC_VIDEO_PORT")?,
            public_host: get("PEERINGD_PUBLIC_HOST"),
            tls,
            session_ttl: Duration::from_secs(seconds(&get, "PEERINGD_SESSION_TTL", 300)?),
            plans: PlanAllowances {
                free_seconds: Some(seconds(&get, "PEERINGD_FREE_MINUTES", DEFAULT_FREE_MINUTES)? * 60),
                relay_seconds: Some(
                    seconds(&get, "PEERINGD_RELAY_MINUTES", DEFAULT_RELAY_MINUTES)? * 60,
                ),
            },
            paid_keys,
            trust_claimed_plans: boolean(&get, "PEERINGD_TRUST_CLAIMED_PLANS", false)?,
            web_addr: address(&get, "PEERINGD_WEB_ADDR", "127.0.0.1:8080")?,
            web_root: get("PEERINGD_WEB_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("site")),
            usage_log: get("PEERINGD_USAGE_LOG").map(PathBuf::from),
            device_bindings: get("PEERINGD_DEVICE_BINDINGS").map(PathBuf::from),
            max_sessions: count(&get, "PEERINGD_MAX_SESSIONS", DEFAULT_MAX_SESSIONS)?,
            max_connections: count(&get, "PEERINGD_MAX_CONNECTIONS", DEFAULT_MAX_CONNECTIONS)?,
            handshake_timeout: Duration::from_secs(seconds(
                &get,
                "PEERINGD_HANDSHAKE_SECONDS",
                DEFAULT_HANDSHAKE_SECONDS,
            )?),
            idle_timeout: Duration::from_secs(seconds(
                &get,
                "PEERINGD_IDLE_SECONDS",
                DEFAULT_IDLE_SECONDS,
            )?),
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

/// A switch, refused rather than guessed when it is neither. `PEERINGD_TRUST_CLAIMED_PLANS=maybe`
/// is a typo, and a typo that silently means "trust every claim" is the one outcome this must not
/// have; `0` and `1` are accepted beside the words because that is how they are written in a
/// compose file.
fn boolean(get: Lookup<'_>, name: &'static str, default: bool) -> Result<bool, ConfigError> {
    match get(name).map(|raw| raw.trim().to_ascii_lowercase()) {
        None => Ok(default),
        Some(raw) => match raw.as_str() {
            "1" | "true" | "yes" | "on" => Ok(true),
            "0" | "false" | "no" | "off" => Ok(false),
            _ => Err(ConfigError::NotABoolean(name, raw)),
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

/// A positive count, for the two ceilings.
///
/// **Zero is refused rather than accepted as "no limit".** A relay configured with no sessions and
/// no connections looks healthy, listens, and answers nothing, which is the sort of outage that
/// gets diagnosed by reading the code rather than the config. An operator who wants no limit has
/// `usize::MAX` and can say so.
fn count(get: Lookup<'_>, name: &'static str, default: usize) -> Result<usize, ConfigError> {
    match get(name) {
        None => Ok(default),
        Some(raw) => match raw.trim().parse::<usize>() {
            Ok(value) if value > 0 => Ok(value),
            _ => Err(ConfigError::BadDuration(name, raw)),
        },
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
            "the relay's one video port must be pickable"
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
    fn the_default_allowances_are_the_ones_the_app_states() {
        let config = configured(&[]).unwrap();

        assert_eq!(config.plans, PlanAllowances::default());
        assert_eq!(config.plans.free_seconds, Some(15 * 60), "free is a quarter of an hour a day");
        assert_eq!(config.plans.relay_seconds, Some(180 * 60), "Relay is three hours a day");
    }

    #[test]
    fn each_allowance_is_configurable_in_minutes() {
        let config = configured(&[
            ("PEERINGD_FREE_MINUTES", "5"),
            ("PEERINGD_RELAY_MINUTES", "600"),
        ])
        .unwrap();

        assert_eq!(config.plans.free_seconds, Some(5 * 60));
        assert_eq!(config.plans.relay_seconds, Some(600 * 60));

        // Zero is a number rather than a spelling of unlimited: it turns the plan off, which is
        // what the operator who sets it is asking for.
        let config = configured(&[("PEERINGD_FREE_MINUTES", "0")]).unwrap();
        assert_eq!(config.plans.free_seconds, Some(0));

        assert!(matches!(
            configured(&[("PEERINGD_RELAY_MINUTES", "three hours")]),
            Err(ConfigError::BadDuration(_, _))
        ));
    }

    /// The switch is closed unless an operator opens it, which is what this default is: an
    /// unproven claim buys the free allowance, and a string a client writes is not enough to buy
    /// anything else. Opening it is a beta-testing decision, so it takes a line in the environment
    /// file rather than being the state a relay falls into.
    #[test]
    fn claims_are_metered_as_free_unless_the_operator_opts_in() {
        assert!(
            !configured(&[]).unwrap().trust_claimed_plans,
            "an unproven plan must not be believed by default"
        );

        for off in ["0", "false", "off", "no", "FALSE", " 0 "] {
            let config = configured(&[("PEERINGD_TRUST_CLAIMED_PLANS", off)]).unwrap();
            assert!(
                !config.trust_claimed_plans,
                "{off:?} should leave the switch closed"
            );
        }

        for on in ["1", "true", "on", "yes"] {
            assert!(
                configured(&[("PEERINGD_TRUST_CLAIMED_PLANS", on)])
                    .unwrap()
                    .trust_claimed_plans,
                "{on:?} should open the switch"
            );
        }
    }

    /// A switch nobody can read is refused rather than guessed. The guess would be the wrong way
    /// round whatever it was, and a typo here decides whether every claim is believed.
    #[test]
    fn a_switch_that_is_not_a_switch_is_refused() {
        assert!(matches!(
            configured(&[("PEERINGD_TRUST_CLAIMED_PLANS", "maybe")]),
            Err(ConfigError::NotABoolean("PEERINGD_TRUST_CLAIMED_PLANS", _))
        ));
    }

    #[test]
    fn a_public_host_is_optional_until_a_proxy_is_in_front() {
        assert!(configured(&[]).unwrap().public_host.is_none());

        let config = configured(&[("PEERINGD_PUBLIC_HOST", "getpeering.app")]).unwrap();
        assert_eq!(config.public_host.as_deref(), Some("getpeering.app"));
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
    fn no_video_bind_configured_means_the_os_chooses() {
        let config = configured(&[]).unwrap();
        assert_eq!(config.video_bind.port(), 0);
    }

    /// The line this replaced. It named the range session video ports were drawn from, and an
    /// existing deployment still has it in its environment file — so a relay that refused to start
    /// over it, or that quietly appeared to honour it, would both be wrong. What is asserted here
    /// is that it parses, that nothing in the configuration takes its value seriously, and that the
    /// raw text survives far enough for startup to say it is being ignored.
    #[test]
    fn a_retired_video_range_is_carried_along_rather_than_refused() {
        // The production value, and the shape the warning matters for: a range of one, which is a
        // ceiling of one session with video. It is now nothing at all.
        let config = configured(&[("PEERINGD_VIDEO_PORTS", "30190-30190")]).unwrap();
        assert_eq!(config.stale_video_ports.as_deref(), Some("30190-30190"));

        // And it is not interpreted, so anything at all gets the same treatment: a value that used
        // to be a hard startup error is now a sentence in the log.
        for nonsense in ["", "40000", "40100-40000", "0-10", "abc-def", "70000-70001"] {
            assert!(
                configured(&[("PEERINGD_VIDEO_PORTS", nonsense)]).is_ok(),
                "{nonsense:?} must not stop the relay from starting"
            );
        }

        assert!(configured(&[]).unwrap().stale_video_ports.is_none());
    }
}
