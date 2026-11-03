//! One HTTP/1.1 exchange with a loopback server, as bytes: the request written, and the answer read as it arrives.

use peering_wire::preview::{PreviewHeader, PreviewProxyRequest};

use super::policy::filtered_request_headers;

const MAXIMUM_HEAD_BYTES: usize = 64 * 1024;

/// The request for `127.0.0.1:<port>`, asking for no compression (the phone gets no `Content-Encoding`) and a close.
pub fn request_bytes(request: &PreviewProxyRequest) -> Vec<u8> {
    let mut head = format!("{} {} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n", request.method, request.target, request.port);
    for header in filtered_request_headers(&request.headers) {
        head.push_str(&format!("{}: {}\r\n", header.name, header.value));
    }
    head.push_str("Accept-Encoding: identity\r\nConnection: close\r\n");
    let body = request.body.as_deref().unwrap_or_default();
    if !body.is_empty() || matches!(request.method.as_str(), "POST" | "PUT" | "PATCH") {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    head.push_str("\r\n");
    let mut bytes = head.into_bytes();
    bytes.extend_from_slice(body);
    bytes
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Piece {
    Head { status: i64, headers: Vec<PreviewHeader> },
    Data(Vec<u8>),
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Malformed {
    NotHttp,
    /// The connection closed before the body said it was complete.
    Incomplete,
}

#[derive(Debug)]
enum Stage {
    Head,
    Length(u64),
    ChunkSize,
    ChunkData(u64),
    ChunkDataEnd,
    Trailer,
    ToClose,
    Done,
}

/// Reads an answer fed in arbitrary pieces.
#[derive(Debug)]
pub struct ResponseReader {
    stage: Stage,
    buffer: Vec<u8>,
    is_head_request: bool,
}

impl ResponseReader {
    pub fn new(method: &str) -> Self {
        Self { stage: Stage::Head, buffer: Vec::new(), is_head_request: method == "HEAD" }
    }

    pub fn is_done(&self) -> bool {
        matches!(self.stage, Stage::Done)
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<Piece>, Malformed> {
        self.buffer.extend_from_slice(bytes);
        let mut pieces = Vec::new();
        while self.step(&mut pieces)? {}
        Ok(pieces)
    }

    /// The server closed the connection.
    pub fn finish(&mut self) -> Result<Vec<Piece>, Malformed> {
        match self.stage {
            Stage::ToClose => {
                self.stage = Stage::Done;
                Ok(vec![Piece::End])
            }
            Stage::Done => Ok(Vec::new()),
            _ => Err(Malformed::Incomplete),
        }
    }

    /// Whether another step may make progress with what is buffered.
    fn step(&mut self, pieces: &mut Vec<Piece>) -> Result<bool, Malformed> {
        match self.stage {
            Stage::Head => self.head(pieces),
            Stage::Length(left) => {
                let taken = self.take(left);
                if !taken.is_empty() {
                    pieces.push(Piece::Data(taken.clone()));
                }
                let left = left - taken.len() as u64;
                self.stage = if left == 0 { self.end(pieces) } else { Stage::Length(left) };
                Ok(left == 0 && !self.buffer.is_empty())
            }
            Stage::ChunkSize | Stage::ChunkDataEnd | Stage::Trailer => self.chunk_line(pieces),
            Stage::ChunkData(left) => {
                let taken = self.take(left);
                if taken.is_empty() {
                    return Ok(false);
                }
                let left = left - taken.len() as u64;
                pieces.push(Piece::Data(taken));
                self.stage = if left == 0 { Stage::ChunkDataEnd } else { Stage::ChunkData(left) };
                Ok(left == 0)
            }
            Stage::ToClose => {
                if !self.buffer.is_empty() {
                    pieces.push(Piece::Data(std::mem::take(&mut self.buffer)));
                }
                Ok(false)
            }
            Stage::Done => Ok(false),
        }
    }

    fn head(&mut self, pieces: &mut Vec<Piece>) -> Result<bool, Malformed> {
        let Some(split) = find(&self.buffer, b"\r\n\r\n") else {
            return if self.buffer.len() > MAXIMUM_HEAD_BYTES { Err(Malformed::NotHttp) } else { Ok(false) };
        };
        let head: Vec<u8> = self.buffer.drain(..split + 4).collect();
        let text = String::from_utf8_lossy(&head[..split]).into_owned();
        let mut lines = text.split("\r\n");
        let status = lines.next().and_then(status_of).ok_or(Malformed::NotHttp)?;
        let headers: Vec<PreviewHeader> = lines
            .filter_map(|line| line.split_once(':'))
            .map(|(name, value)| PreviewHeader { name: name.trim().to_owned(), value: value.trim().to_owned() })
            .collect();
        if (100..200).contains(&status) {
            return Ok(true);
        }
        let value = |name: &str| headers.iter().find(|header| header.name.eq_ignore_ascii_case(name)).map(|h| h.value.clone());
        let chunked = value("transfer-encoding").is_some_and(|value| value.to_ascii_lowercase().contains("chunked"));
        let length = value("content-length").and_then(|value| value.parse::<u64>().ok());
        pieces.push(Piece::Head { status, headers });
        self.stage = if self.is_head_request || status == 204 || status == 304 {
            self.end(pieces)
        } else if chunked {
            Stage::ChunkSize
        } else if let Some(length) = length {
            if length == 0 { self.end(pieces) } else { Stage::Length(length) }
        } else {
            Stage::ToClose
        };
        Ok(!self.buffer.is_empty())
    }

    fn chunk_line(&mut self, pieces: &mut Vec<Piece>) -> Result<bool, Malformed> {
        let Some(end) = find(&self.buffer, b"\r\n") else { return Ok(false) };
        let line: Vec<u8> = self.buffer.drain(..end + 2).collect();
        let line = String::from_utf8_lossy(&line[..end]).into_owned();
        self.stage = match self.stage {
            Stage::ChunkDataEnd if line.is_empty() => Stage::ChunkSize,
            Stage::ChunkDataEnd => return Err(Malformed::NotHttp),
            Stage::Trailer if line.is_empty() => self.end(pieces),
            Stage::Trailer => Stage::Trailer,
            _ => {
                let size = line.split(';').next().unwrap_or_default().trim();
                match u64::from_str_radix(size, 16).map_err(|_| Malformed::NotHttp)? {
                    0 => Stage::Trailer,
                    size => Stage::ChunkData(size),
                }
            }
        };
        Ok(!self.is_done())
    }

    fn take(&mut self, most: u64) -> Vec<u8> {
        let count = self.buffer.len().min(usize::try_from(most).unwrap_or(usize::MAX));
        self.buffer.drain(..count).collect()
    }

    fn end(&mut self, pieces: &mut Vec<Piece>) -> Stage {
        pieces.push(Piece::End);
        Stage::Done
    }
}

fn status_of(line: &str) -> Option<i64> {
    let mut parts = line.split(' ');
    parts.next().filter(|version| version.starts_with("HTTP/"))?;
    parts.next()?.parse().ok()
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

#[cfg(test)]
mod tests;
