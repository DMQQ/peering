//! Reading the answer to one HTTP/1.1 request that asked for the connection to close: the status, and a body that is either
//! sized by `Content-Length`, sent in chunks, or runs to the end of the connection. Just enough for the update check.

use thiserror::Error;

/// More than this is not the list of releases, and is not kept.
pub const MAXIMUM_RESPONSE_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum HttpError {
    #[error("the answer was cut short")]
    Incomplete,
    #[error("the answer is not HTTP")]
    NotHttp,
    #[error("the server answered {0}")]
    Status(u16),
    #[error("the body is malformed")]
    BadBody,
}

/// The body of a 200 answer in `bytes`, which holds everything the server sent until it closed the connection.
pub fn body_of(bytes: &[u8]) -> Result<Vec<u8>, HttpError> {
    let split = find(bytes, b"\r\n\r\n").ok_or(HttpError::Incomplete)?;
    let head = std::str::from_utf8(&bytes[..split]).map_err(|_| HttpError::NotHttp)?;
    let rest = &bytes[split + 4..];
    let mut lines = head.split("\r\n");
    let status = lines.next().and_then(status_of).ok_or(HttpError::NotHttp)?;
    if status != 200 {
        return Err(HttpError::Status(status));
    }
    let mut length = None;
    let mut chunked = false;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        match name.trim().to_ascii_lowercase().as_str() {
            "content-length" => length = value.trim().parse::<usize>().ok(),
            "transfer-encoding" => chunked = value.to_ascii_lowercase().contains("chunked"),
            _ => {}
        }
    }
    if chunked {
        return dechunked(rest);
    }
    match length {
        Some(length) if rest.len() >= length => Ok(rest[..length].to_vec()),
        Some(_) => Err(HttpError::Incomplete),
        None => Ok(rest.to_vec()),
    }
}

fn status_of(line: &str) -> Option<u16> {
    let mut parts = line.split(' ');
    parts.next().filter(|version| version.starts_with("HTTP/"))?;
    parts.next()?.parse().ok()
}

fn dechunked(mut rest: &[u8]) -> Result<Vec<u8>, HttpError> {
    let mut body = Vec::new();
    loop {
        let line_end = find(rest, b"\r\n").ok_or(HttpError::Incomplete)?;
        let size_text = std::str::from_utf8(&rest[..line_end]).map_err(|_| HttpError::BadBody)?;
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16).map_err(|_| HttpError::BadBody)?;
        rest = &rest[line_end + 2..];
        if size == 0 {
            return Ok(body);
        }
        if rest.len() < size + 2 {
            return Err(HttpError::Incomplete);
        }
        body.extend_from_slice(&rest[..size]);
        if &rest[size..size + 2] != b"\r\n" {
            return Err(HttpError::BadBody);
        }
        rest = &rest[size + 2..];
        if body.len() > MAXIMUM_RESPONSE_BYTES {
            return Err(HttpError::BadBody);
        }
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sized_body_is_cut_to_its_length() {
        let answer = b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello and more";
        assert_eq!(body_of(answer), Ok(b"hello".to_vec()));
    }

    #[test]
    fn a_body_without_a_length_runs_to_the_end() {
        assert_eq!(body_of(b"HTTP/1.1 200 OK\r\n\r\nrest of it"), Ok(b"rest of it".to_vec()));
    }

    #[test]
    fn a_chunked_body_is_put_back_together() {
        let answer = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n";
        assert_eq!(body_of(answer), Ok(b"hello world".to_vec()));
    }

    #[test]
    fn header_names_are_matched_without_regard_to_case() {
        let answer = b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nokay";
        assert_eq!(body_of(answer), Ok(b"ok".to_vec()));
    }

    #[test]
    fn an_answer_that_is_not_a_success_names_its_status() {
        assert_eq!(body_of(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"), Err(HttpError::Status(403)));
        assert_eq!(body_of(b"HTTP/1.1 301 Moved\r\nLocation: x\r\n\r\n"), Err(HttpError::Status(301)));
    }

    #[test]
    fn a_connection_that_closed_early_is_incomplete() {
        assert_eq!(body_of(b"HTTP/1.1 200 OK\r\nContent-Le"), Err(HttpError::Incomplete));
        assert_eq!(body_of(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort"), Err(HttpError::Incomplete));
        assert_eq!(body_of(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"), Err(HttpError::Incomplete));
    }

    #[test]
    fn something_that_is_not_http_is_refused() {
        assert_eq!(body_of(b"SSH-2.0-OpenSSH\r\n\r\n"), Err(HttpError::NotHttp));
        assert_eq!(body_of(b"\xff\xfe\r\n\r\n"), Err(HttpError::NotHttp));
    }

    #[test]
    fn a_chunk_size_that_is_not_hex_is_a_bad_body() {
        let answer = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n";
        assert_eq!(body_of(answer), Err(HttpError::BadBody));
    }

    #[test]
    fn a_chunk_not_followed_by_a_line_break_is_a_bad_body() {
        let answer = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n";
        assert_eq!(body_of(answer), Err(HttpError::BadBody));
    }
}
