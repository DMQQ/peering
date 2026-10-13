//! Recognises the marker a terminal's shell hook prints when a long command returns to the prompt: an OSC sequence
//! private to this app, which real terminals swallow as unrecognised. Mirrors `TerminalCommandFinishDetector.swift`.

use base64::alphabet;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use base64::Engine;

const MAXIMUM_TAIL_BYTES: usize = 4_096;
const MARKER: &[u8] = b"\x1b]9999;";
const BEL: u8 = 0x07;
const ESC: u8 = 0x1b;

/// Anything longer reads the same: a marker is printed by whatever runs in the terminal, so the number is not to be trusted.
pub const MAXIMUM_DURATION_SECONDS: f64 = 30.0 * 24.0 * 3_600.0;

const LENIENT_BASE64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

#[derive(Debug, Clone, PartialEq)]
pub struct Finish {
    pub command: Option<String>,
    pub duration: f64,
    pub exit_status: i32,
}

#[derive(Debug, Default)]
pub struct FinishDetector {
    tail: Vec<u8>,
}

impl FinishDetector {
    /// At most one marker per call; bytes through its terminator are dropped so it is never matched twice.
    pub fn receive(&mut self, data: &[u8]) -> Option<Finish> {
        if data.is_empty() {
            return None;
        }
        self.tail.extend_from_slice(data);
        if self.tail.len() > MAXIMUM_TAIL_BYTES {
            let excess = self.tail.len() - MAXIMUM_TAIL_BYTES;
            self.tail.drain(..excess);
        }
        let body_start = find(&self.tail, MARKER)? + MARKER.len();
        // BEL is what the hook sends; ESC (the start of ST) is accepted as the attention detector's patterns do.
        let terminator = body_start + self.tail[body_start..].iter().position(|&byte| byte == BEL || byte == ESC)?;
        let body = String::from_utf8_lossy(&self.tail[body_start..terminator]).into_owned();
        self.tail.drain(..=terminator);
        parse(&body)
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn parse(body: &str) -> Option<Finish> {
    let mut parts = body.splitn(3, ';');
    let (duration_ms, status, command) = (parts.next()?, parts.next()?, parts.next()?);
    let duration_ms: f64 = duration_ms.parse().ok().filter(|value: &f64| value.is_finite() && *value >= 0.0)?;
    let exit_status: i32 = status.parse().ok()?;
    let command = LENIENT_BASE64.decode(command).ok().and_then(|bytes| String::from_utf8(bytes).ok());
    Some(Finish { command, duration: (duration_ms / 1_000.0).min(MAXIMUM_DURATION_SECONDS), exit_status })
}

/// Shared by the push body and the phone's banner so the two sentences cannot drift.
pub fn duration_suffix(duration: f64) -> String {
    let bounded = if duration.is_nan() { 0.0 } else { duration.clamp(0.0, MAXIMUM_DURATION_SECONDS) };
    let total_seconds = bounded.round() as u64;
    let (minutes, seconds) = (total_seconds / 60, total_seconds % 60);
    if minutes == 0 {
        return format!(" after {seconds}s");
    }
    let (hours, remaining_minutes) = (minutes / 60, minutes % 60);
    if hours == 0 {
        return format!(" after {minutes}m {seconds}s");
    }
    format!(" after {hours}h {remaining_minutes}m")
}

#[cfg(test)]
mod tests;
