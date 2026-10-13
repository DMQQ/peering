//! Reads one HTTP request head from a hook's `curl`, and nothing it does not need.

pub const TOKEN_HEADER: &str = "x-peering-token";
pub const HOOK_PATH: &str = "/hook";
pub const MAXIMUM_HEAD_BYTES: usize = 16 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    Malformed,
    NotFound,
    Forbidden,
    TooLarge,
}

impl Refusal {
    pub fn status_line(&self) -> &'static str {
        match self {
            Self::Malformed => "400 Bad Request",
            Self::NotFound => "404 Not Found",
            Self::Forbidden => "403 Forbidden",
            Self::TooLarge => "413 Payload Too Large",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct Head {
    pub content_length: usize,
}

/// The index just past the blank line that ends the head, once it has arrived.
pub fn head_end(received: &[u8]) -> Option<usize> {
    received.windows(4).position(|window| window == b"\r\n\r\n").map(|index| index + 4)
}

pub fn parse_head(head: &[u8], token: &str, maximum_body: usize) -> Result<Head, Refusal> {
    if head.len() > MAXIMUM_HEAD_BYTES {
        return Err(Refusal::TooLarge);
    }
    let text = std::str::from_utf8(head).map_err(|_| Refusal::Malformed)?;
    let mut lines = text.split("\r\n");
    let mut request_line = lines.next().unwrap_or_default().split(' ');
    let (method, path) = (request_line.next(), request_line.next());
    if method != Some("POST") || path != Some(HOOK_PATH) {
        return Err(Refusal::NotFound);
    }
    let mut presented = None;
    let mut content_length = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        match name.trim().to_ascii_lowercase().as_str() {
            TOKEN_HEADER => presented = Some(value.trim()),
            "content-length" => content_length = value.trim().parse::<usize>().ok(),
            _ => {}
        }
    }
    let matches = presented.is_some_and(|given| same_bytes(given.as_bytes(), token.as_bytes()));
    if !matches {
        return Err(Refusal::Forbidden);
    }
    match content_length {
        None => Err(Refusal::Malformed),
        Some(length) if length > maximum_body => Err(Refusal::TooLarge),
        Some(content_length) => Ok(Head { content_length }),
    }
}

/// Compares without stopping at the first difference, so the time taken does not say how much of a guess was right.
fn same_bytes(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len() && left.iter().zip(right).fold(0u8, |difference, (a, b)| difference | (a ^ b)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn head(token: &str, extra: &str) -> Vec<u8> {
        format!("POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Peering-Token: {token}\r\n{extra}\r\n").into_bytes()
    }

    #[test]
    fn a_request_with_the_token_and_a_length_is_accepted() {
        assert_eq!(parse_head(&head("abc", "Content-Length: 12\r\n"), "abc", 100), Ok(Head { content_length: 12 }));
    }

    #[test]
    fn a_wrong_or_missing_token_is_forbidden() {
        assert_eq!(parse_head(&head("nope", "Content-Length: 1\r\n"), "abc", 100), Err(Refusal::Forbidden));
        assert_eq!(parse_head(b"POST /hook HTTP/1.1\r\nContent-Length: 1\r\n\r\n", "abc", 100), Err(Refusal::Forbidden));
    }

    #[test]
    fn another_path_or_method_is_not_found() {
        assert_eq!(parse_head(b"GET /hook HTTP/1.1\r\n\r\n", "abc", 100), Err(Refusal::NotFound));
        assert_eq!(parse_head(b"POST /other HTTP/1.1\r\n\r\n", "abc", 100), Err(Refusal::NotFound));
    }

    #[test]
    fn a_body_over_the_bound_is_refused_before_it_is_read() {
        assert_eq!(parse_head(&head("abc", "Content-Length: 101\r\n"), "abc", 100), Err(Refusal::TooLarge));
    }

    #[test]
    fn a_missing_or_unreadable_length_is_malformed() {
        assert_eq!(parse_head(&head("abc", ""), "abc", 100), Err(Refusal::Malformed));
        assert_eq!(parse_head(&head("abc", "Content-Length: many\r\n"), "abc", 100), Err(Refusal::Malformed));
    }

    #[test]
    fn the_head_ends_at_the_blank_line() {
        assert_eq!(head_end(b"POST /hook HTTP/1.1\r\n\r\nbody"), Some(23));
        assert_eq!(head_end(b"POST /hook HTTP/1.1\r\n"), None);
    }
}
