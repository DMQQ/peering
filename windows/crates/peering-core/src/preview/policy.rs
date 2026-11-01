//! What the host will fetch for the phone's web preview. Mirrors `PreviewProxyPolicy.swift`: it dials `127.0.0.1` and
//! nothing else, on the port the request names, and refuses the port this host itself listens on.

use std::sync::LazyLock;

use peering_wire::preview::{
    PreviewFailure, PreviewHeader, PreviewProxyRequest, MAX_HEADER_COUNT, MAX_REQUEST_BODY_BYTES, MAX_TARGET_LENGTH,
};
use regex::Regex;

use crate::settings::DEFAULT_PORT;

const ALLOWED_METHODS: [&str; 7] = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"];

const REQUEST_HEADERS: [&str; 11] = [
    "accept", "accept-language", "content-type", "user-agent", "if-none-match", "if-modified-since", "range",
    "authorization", "cookie", "origin", "referer",
];

const RESPONSE_HEADERS: [&str; 17] = [
    "content-type", "cache-control", "etag", "last-modified", "expires", "content-language", "content-disposition",
    "location", "accept-ranges", "content-range", "vary", "access-control-allow-origin",
    "access-control-allow-credentials", "access-control-allow-methods", "access-control-allow-headers",
    "access-control-expose-headers", "access-control-max-age",
];

/// `listening` is the port this host serves phones on, which may differ from the default.
pub fn is_allowed_port(port: u16, listening: u16) -> bool {
    port != 0 && port != DEFAULT_PORT && port != listening
}

/// `None` when the request may be served.
pub fn refusal(request: &PreviewProxyRequest, listening: u16) -> Option<PreviewFailure> {
    if !is_allowed_port(request.port, listening) || !ALLOWED_METHODS.contains(&request.method.as_str()) {
        return Some(PreviewFailure::NotAllowed);
    }
    if !is_valid_target(&request.target) || request.headers.len() > MAX_HEADER_COUNT {
        return Some(PreviewFailure::InvalidRequest);
    }
    if request.body.as_ref().is_some_and(|body| body.len() > MAX_REQUEST_BODY_BYTES) {
        return Some(PreviewFailure::TooLarge);
    }
    None
}

/// A single leading `/` and nothing that could turn the string into another authority or split a header.
pub fn is_valid_target(target: &str) -> bool {
    if !target.starts_with('/') || target.starts_with("//") || target.len() > MAX_TARGET_LENGTH {
        return false;
    }
    target.chars().all(|c| (c as u32) > 0x20 && c != '\u{7f}' && c != '\\')
}

/// Only what a page needs; `Origin` and `Referer` are put back to the `http://localhost:<port>` the server expects.
pub fn filtered_request_headers(headers: &[PreviewHeader]) -> Vec<PreviewHeader> {
    headers
        .iter()
        .filter(|header| {
            let name = header.name.to_ascii_lowercase();
            (REQUEST_HEADERS.contains(&name.as_str()) || name.starts_with("x-")) && is_safe(header)
        })
        .map(|header| PreviewHeader { name: header.name.clone(), value: restoring_http_urls(&header.value) })
        .collect()
}

/// `Set-Cookie`, security policies and framing headers are dropped: the page lives under another scheme.
pub fn filtered_response_headers(headers: Vec<PreviewHeader>) -> Vec<PreviewHeader> {
    headers
        .into_iter()
        .filter(|header| RESPONSE_HEADERS.contains(&header.name.to_ascii_lowercase().as_str()) && is_safe(header))
        .collect()
}

pub fn restoring_http_urls(text: &str) -> String {
    static PREVIEW_ORIGIN: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"peering-preview://localhost:(\d{1,5})(\D|$)").expect("a valid pattern"));
    PREVIEW_ORIGIN.replace_all(text, "http://localhost:$1$2").into_owned()
}

fn is_safe(header: &PreviewHeader) -> bool {
    let forbidden = |c: char| c == '\r' || c == '\n' || c == '\0';
    !header.name.is_empty() && !header.name.contains(':') && !header.name.contains(forbidden) && !header.value.contains(forbidden)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(port: u16, method: &str, target: &str) -> PreviewProxyRequest {
        PreviewProxyRequest { id: 1, port, method: method.to_owned(), target: target.to_owned(), headers: Vec::new(), body: None }
    }

    fn header(name: &str, value: &str) -> PreviewHeader {
        PreviewHeader { name: name.to_owned(), value: value.to_owned() }
    }

    #[test]
    fn the_hosts_own_ports_and_odd_methods_are_not_allowed() {
        assert_eq!(refusal(&request(3000, "GET", "/"), 51515), None);
        for (port, method) in [(0, "GET"), (51515, "GET"), (6000, "GET"), (3000, "CONNECT"), (3000, "get")] {
            assert_eq!(refusal(&request(port, method, "/"), 6000), Some(PreviewFailure::NotAllowed), "{port} {method}");
        }
    }

    #[test]
    fn a_target_that_could_name_another_authority_is_invalid() {
        for bad in ["", "x", "//evil.example/", "/a b", "/a\\b", "/\r\n"] {
            assert_eq!(refusal(&request(3000, "GET", bad), 51515), Some(PreviewFailure::InvalidRequest), "{bad:?}");
        }
        let long = format!("/{}", "a".repeat(MAX_TARGET_LENGTH));
        assert!(!is_valid_target(&long));
    }

    #[test]
    fn a_large_body_is_too_large() {
        let big = PreviewProxyRequest { body: Some(vec![0; MAX_REQUEST_BODY_BYTES + 1]), ..request(3000, "POST", "/") };
        assert_eq!(refusal(&big, 51515), Some(PreviewFailure::TooLarge));
    }

    #[test]
    fn request_headers_keep_what_a_page_needs_and_restore_the_origin() {
        let kept = filtered_request_headers(&[
            header("Origin", "peering-preview://localhost:3000"),
            header("Host", "evil"),
            header("X-Token", "t"),
            header("Cookie", "a\r\nb"),
        ]);
        assert_eq!(kept, [header("Origin", "http://localhost:3000"), header("X-Token", "t")]);
    }

    #[test]
    fn response_headers_drop_cookies_and_framing() {
        let kept = filtered_response_headers(vec![
            header("Content-Type", "text/html"),
            header("Set-Cookie", "a=b"),
            header("Transfer-Encoding", "chunked"),
        ]);
        assert_eq!(kept, [header("Content-Type", "text/html")]);
    }
}
