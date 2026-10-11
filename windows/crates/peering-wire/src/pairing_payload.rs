//! Pairing QR payloads. `peering://pair?code=NNNNNN[&secret=hex]` carries the six digit code that both screens
//! compare. `https://getpeering.app/mac?id=<UUID>` carries the Mac's device ID. Each parser refuses the other's
//! payload, so a scan of the wrong code is reported as a mismatch rather than read as the other thing.

use thiserror::Error;

const SCHEME: &str = "peering";
const CODE_HOST: &str = "pair";
const IDENTIFIER_HOST: &str = "mac";
const CODE_KEY: &str = "code";
const SECRET_KEY: &str = "secret";
const LINK_DOMAIN: &str = "getpeering.app";
const LINK_PATH: &str = "/mac";
const IDENTIFIER_KEY: &str = "id";
const CODE_DIGITS: usize = 6;
const UUID_LENGTH: usize = 36;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum PairingPayloadError {
    #[error("no device ID was given")]
    Empty,
    #[error("the six digit pairing code was given where the device ID belongs")]
    ShortAuthenticationCode,
    #[error("the QR code is not a Peering pairing code")]
    Unrecognised,
    #[error("not a device ID: {0}")]
    NotAnIdentifier(String),
}

/// The device ID link shown beside the Mac's device ID. The ID is written uppercase, because the relay matches it exactly.
pub fn host_link(host_id: &str) -> String {
    format!("https://{LINK_DOMAIN}{LINK_PATH}?{IDENTIFIER_KEY}={}", host_id.to_ascii_uppercase())
}

/// The pairing code link. The secret, when given, is lowercase hex.
pub fn code_link(code: &str, secret: Option<&[u8]>) -> String {
    let mut link = format!("{SCHEME}://{CODE_HOST}?{CODE_KEY}={code}");
    if let Some(secret) = secret {
        link.push_str(&format!("&{SECRET_KEY}={}", hex::encode(secret)));
    }
    link
}

/// The six digit code from raw text, which is either the bare digits or a pairing code link.
pub fn parse_code(raw: &str) -> Option<String> {
    let text = raw.trim();
    if is_short_authentication_code(text) {
        return Some(text.to_owned());
    }
    let link = Link::parse(text)?;
    if link.scheme != SCHEME || link.host != CODE_HOST {
        return None;
    }
    let code = query_value(&link.query, CODE_KEY)?;
    is_short_authentication_code(code).then(|| code.to_owned())
}

/// The pairing secret carried by a pairing code link. `None` for a code without one, or a secret that is not hex.
pub fn parse_secret(raw: &str) -> Option<Vec<u8>> {
    let link = Link::parse(raw.trim())?;
    if link.scheme != SCHEME || link.host != CODE_HOST {
        return None;
    }
    let secret = query_value(&link.query, SECRET_KEY)?;
    let bytes = hex::decode(secret).ok()?;
    (!bytes.is_empty()).then_some(bytes)
}

/// The uppercase device ID from a bare UUID or a device ID link. Refuses the pairing code, which looks like a number.
pub fn parse_host_id(raw: &str) -> Result<String, PairingPayloadError> {
    let text = raw.trim();
    if text.is_empty() {
        return Err(PairingPayloadError::Empty);
    }
    if is_uuid(text) {
        return Ok(text.to_ascii_uppercase());
    }
    if is_short_authentication_code(text) {
        return Err(PairingPayloadError::ShortAuthenticationCode);
    }
    let Some(link) = Link::parse(text) else {
        return Err(if has_scheme_prefix(text) {
            PairingPayloadError::Unrecognised
        } else {
            PairingPayloadError::NotAnIdentifier(text.to_owned())
        });
    };
    match (link.scheme.as_str(), link.host.as_str()) {
        ("https", host) if is_device_link_host(host) && link.path == LINK_PATH => identifier_in(&link),
        (SCHEME, CODE_HOST) => Err(PairingPayloadError::ShortAuthenticationCode),
        (SCHEME, IDENTIFIER_HOST) => identifier_in(&link),
        _ => Err(PairingPayloadError::Unrecognised),
    }
}

fn identifier_in(link: &Link) -> Result<String, PairingPayloadError> {
    let value = query_value(&link.query, IDENTIFIER_KEY).unwrap_or("");
    if is_uuid(value) {
        Ok(value.to_ascii_uppercase())
    } else {
        Err(PairingPayloadError::NotAnIdentifier(value.to_owned()))
    }
}

fn is_device_link_host(host: &str) -> bool {
    host == LINK_DOMAIN || host == format!("www.{LINK_DOMAIN}")
}

fn is_short_authentication_code(text: &str) -> bool {
    text.len() == CODE_DIGITS && text.bytes().all(|byte| byte.is_ascii_digit())
}

fn is_uuid(text: &str) -> bool {
    text.len() == UUID_LENGTH
        && text.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

/// `scheme:` with a plain letter scheme, so `WIFI:S:...` reads as another format and `my mac` as a mistyped ID.
fn has_scheme_prefix(text: &str) -> bool {
    text.split_once(':')
        .is_some_and(|(scheme, _)| !scheme.is_empty() && scheme.bytes().all(|byte| byte.is_ascii_alphabetic()))
}

fn query_value<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    query.split('&').find_map(|pair| {
        let (name, value) = pair.split_once('=')?;
        (name == key).then_some(value)
    })
}

/// A URL split into the parts the parsers compare. The scheme and host are lowercased; the query is left as written,
/// since every value we read (digits, hex, UUID) needs no percent decoding.
struct Link {
    scheme: String,
    host: String,
    path: String,
    query: String,
}

impl Link {
    fn parse(text: &str) -> Option<Link> {
        let without_fragment = text.split('#').next().unwrap_or("");
        let (scheme, rest) = without_fragment.split_once("://")?;
        if scheme.is_empty() || !scheme.bytes().all(|byte| byte.is_ascii_alphabetic()) {
            return None;
        }
        let (before_query, query) = rest.split_once('?').unwrap_or((rest, ""));
        let (authority, path) = match before_query.find('/') {
            Some(index) => before_query.split_at(index),
            None => (before_query, ""),
        };
        Some(Link {
            scheme: scheme.to_ascii_lowercase(),
            host: authority.to_ascii_lowercase(),
            path: path.to_owned(),
            query: query.to_owned(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST_ID: &str = "3D9F1C7A-2B44-4E71-9C0A-5F2E8B1D6A33";

    #[test]
    fn host_link_writes_the_id_uppercase_and_hyphenated() {
        assert_eq!(host_link(HOST_ID), "https://getpeering.app/mac?id=3D9F1C7A-2B44-4E71-9C0A-5F2E8B1D6A33");
        assert_eq!(host_link(&HOST_ID.to_ascii_lowercase()), host_link(HOST_ID));
    }

    #[test]
    fn code_link_without_a_secret_is_the_bare_code() {
        assert_eq!(code_link("042317", None), "peering://pair?code=042317");
    }

    #[test]
    fn code_link_writes_the_secret_as_lowercase_hex() {
        assert_eq!(code_link("000001", Some(&[0x0a, 0xff])), "peering://pair?code=000001&secret=0aff");
    }

    #[test]
    fn parse_code_accepts_bare_digits_and_keeps_leading_zeros() {
        assert_eq!(parse_code("000000"), Some("000000".to_owned()));
        assert_eq!(parse_code(" 042317\n"), Some("042317".to_owned()));
    }

    #[test]
    fn parse_code_reads_the_code_from_a_pairing_link_with_leading_zeros() {
        assert_eq!(parse_code("peering://pair?code=007000"), Some("007000".to_owned()));
        assert_eq!(parse_code(&code_link("000123", Some(&[1, 2]))), Some("000123".to_owned()));
    }

    #[test]
    fn parse_code_refuses_anything_that_is_not_six_digits() {
        assert_eq!(parse_code("04231"), None);
        assert_eq!(parse_code("0423178"), None);
        assert_eq!(parse_code("04231x"), None);
        assert_eq!(parse_code(""), None);
        assert_eq!(parse_code("peering://pair?code=04231"), None);
        assert_eq!(parse_code("https://example.com/?code=042317"), None);
        assert_eq!(parse_code("peering://mac?code=042317"), None);
    }

    #[test]
    fn parse_secret_decodes_hex_in_either_case() {
        assert_eq!(parse_secret("peering://pair?code=042317&secret=0aff"), Some(vec![0x0a, 0xff]));
        assert_eq!(parse_secret("peering://pair?code=042317&secret=0AFF"), Some(vec![0x0a, 0xff]));
    }

    #[test]
    fn parse_secret_round_trips_through_code_link() {
        let secret = [0u8, 15, 16, 255];
        assert_eq!(parse_secret(&code_link("123456", Some(&secret))), Some(secret.to_vec()));
    }

    #[test]
    fn parse_secret_is_none_without_a_usable_secret() {
        assert_eq!(parse_secret("peering://pair?code=042317"), None);
        assert_eq!(parse_secret("peering://pair?code=042317&secret="), None);
        assert_eq!(parse_secret("peering://pair?code=042317&secret=abc"), None);
        assert_eq!(parse_secret("peering://pair?code=042317&secret=zz"), None);
        assert_eq!(parse_secret("https://getpeering.app/mac?id=x&secret=0aff"), None);
    }

    #[test]
    fn host_id_round_trips_through_host_link() {
        assert_eq!(parse_host_id(&host_link(HOST_ID)), Ok(HOST_ID.to_owned()));
    }

    #[test]
    fn host_id_accepts_a_bare_uuid_with_surrounding_space() {
        assert_eq!(parse_host_id(&format!("  {HOST_ID}\n")), Ok(HOST_ID.to_owned()));
    }

    #[test]
    fn host_id_is_uppercased_whatever_the_case_it_arrives_in() {
        let lower = HOST_ID.to_ascii_lowercase();
        assert_eq!(parse_host_id(&lower), Ok(HOST_ID.to_owned()));
        assert_eq!(parse_host_id(&format!("https://getpeering.app/mac?id={lower}")), Ok(HOST_ID.to_owned()));
    }

    #[test]
    fn host_id_accepts_the_www_host_and_the_older_scheme() {
        assert_eq!(parse_host_id(&format!("https://www.getpeering.app/mac?id={HOST_ID}")), Ok(HOST_ID.to_owned()));
        assert_eq!(parse_host_id(&format!("peering://mac?id={HOST_ID}")), Ok(HOST_ID.to_owned()));
    }

    #[test]
    fn six_digits_are_refused_as_the_pairing_code() {
        assert_eq!(parse_host_id("123456"), Err(PairingPayloadError::ShortAuthenticationCode));
        assert_eq!(parse_host_id(&code_link("042317", None)), Err(PairingPayloadError::ShortAuthenticationCode));
    }

    #[test]
    fn digits_of_another_length_are_not_read_as_the_pairing_code() {
        assert_eq!(parse_host_id("12345"), Err(PairingPayloadError::NotAnIdentifier("12345".to_owned())));
        assert_eq!(parse_host_id("1234567"), Err(PairingPayloadError::NotAnIdentifier("1234567".to_owned())));
    }

    #[test]
    fn other_schemes_and_hosts_are_unrecognised() {
        assert_eq!(parse_host_id(&format!("https://example.com/mac?id={HOST_ID}")), Err(PairingPayloadError::Unrecognised));
        assert_eq!(parse_host_id(&format!("https://getpeering.app/download?id={HOST_ID}")), Err(PairingPayloadError::Unrecognised));
        assert_eq!(parse_host_id("peering://connect"), Err(PairingPayloadError::Unrecognised));
        assert_eq!(parse_host_id("WIFI:S:Cafe;T:WPA;P:hunter2;;"), Err(PairingPayloadError::Unrecognised));
    }

    #[test]
    fn bad_ids_are_not_identifiers() {
        let compact = HOST_ID.replace('-', "");
        assert_eq!(parse_host_id(&compact), Err(PairingPayloadError::NotAnIdentifier(compact.clone())));
        assert_eq!(parse_host_id("peering://mac?id=hello"), Err(PairingPayloadError::NotAnIdentifier("hello".to_owned())));
        assert_eq!(parse_host_id("peering://mac"), Err(PairingPayloadError::NotAnIdentifier(String::new())));
        assert_eq!(parse_host_id("my mac"), Err(PairingPayloadError::NotAnIdentifier("my mac".to_owned())));
    }

    #[test]
    fn empty_input_is_its_own_error() {
        assert_eq!(parse_host_id(""), Err(PairingPayloadError::Empty));
        assert_eq!(parse_host_id("   "), Err(PairingPayloadError::Empty));
    }

    #[test]
    fn each_payload_is_refused_by_the_other_parser() {
        let id_link = host_link(HOST_ID);
        let code = code_link("042317", None);
        assert_eq!(parse_code(&id_link), None);
        assert_eq!(parse_host_id(&code), Err(PairingPayloadError::ShortAuthenticationCode));
    }
}
