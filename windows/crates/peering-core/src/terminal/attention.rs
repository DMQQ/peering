//! Recognises terminal output that has stopped for a person's answer. Mirrors `TerminalAttentionDetector.swift`.
//!
//! A prompt may be split across reads and full-screen tools redraw it, so the detector keeps a short tail and
//! reports one attention until `user_did_respond` says the person has answered.

use std::sync::LazyLock;

use peering_wire::terminal::TerminalAttentionKind;
use regex::Regex;

use super::text::{lines, trim_horizontal};

const MAXIMUM_TAIL_BYTES: usize = 4_096;
const CANDIDATE_CHARACTERS: usize = 1_200;
const MAXIMUM_QUESTION_CHARACTERS: usize = 80;
const MAXIMUM_CHOOSER_QUESTION_CHARACTERS: usize = 160;

fn pattern(source: &str) -> Regex {
    Regex::new(source).unwrap_or_else(|error| unreachable!("a fixed pattern compiles: {error}"))
}

static CSI: LazyLock<Regex> = LazyLock::new(|| pattern(r"\x1b\[[0-?]*[ -/]*[@-~]"));
static OSC: LazyLock<Regex> = LazyLock::new(|| pattern(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"));
static PASSWORD: LazyLock<Regex> = LazyLock::new(|| pattern(r"(?:password|passphrase)(?: for [^:\n]+)?:\s*$"));
static CONVENTIONAL: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"(?:\[|\()(?:y/n|yes/no)(?:\]|\))\??\s*$",
        r"are you sure[^\n]*\??\s*$",
        r"press (?:enter|return)[^\n]*\n?$",
        r"continue\?\s*$",
    ]
    .into_iter()
    .map(pattern)
    .collect()
});
static SELECTED_CHOICE: LazyLock<Regex> = LazyLock::new(|| pattern(r"^\s*❯\s*\d+\.\s*.+"));
static ANY_CHOICE: LazyLock<Regex> = LazyLock::new(|| pattern(r"^\s*(?:❯\s*)?\d+\.\s*.+"));
static NUMBERED: LazyLock<Regex> = LazyLock::new(|| pattern(r"^\d+\.\s"));

#[derive(Debug, Default)]
pub struct AttentionDetector {
    tail: Vec<u8>,
    awaiting_response: bool,
}

impl AttentionDetector {
    pub fn receive(&mut self, data: &[u8]) -> Option<TerminalAttentionKind> {
        if data.is_empty() {
            return None;
        }
        self.tail.extend_from_slice(data);
        if self.tail.len() > MAXIMUM_TAIL_BYTES {
            let excess = self.tail.len() - MAXIMUM_TAIL_BYTES;
            self.tail.drain(..excess);
        }
        if self.awaiting_response {
            return None;
        }
        let kind = detect(&String::from_utf8_lossy(&self.tail))?;
        self.awaiting_response = true;
        Some(kind)
    }

    pub fn user_did_respond(&mut self) {
        self.tail.clear();
        self.awaiting_response = false;
    }

    /// The question being asked: the prompt itself, so "[sudo] password for me:" says which password and whose.
    /// `None` when the tail is not readable text, as a full-screen program's repaint is not.
    pub fn question(&self) -> Option<String> {
        let plain = plain(&String::from_utf8_lossy(&self.tail));
        chooser_question(&plain).or_else(|| last_line(&plain))
    }
}

/// Strips cursor, colour and clear sequences and window titles so only drawn text remains.
fn plain(raw: &str) -> String {
    let without_csi = CSI.replace_all(raw, "");
    OSC.replace_all(&without_csi, "").into_owned()
}

/// The question above a Claude Code chooser, whose last line is a footer that says nothing about what is asked.
fn chooser_question(text: &str) -> Option<String> {
    let all: Vec<&str> = lines(text).collect();
    let selected = all.iter().rposition(|line| SELECTED_CHOICE.is_match(line))?;
    for line in all[..selected].iter().rev() {
        let cleaned = trim_horizontal(line);
        if NUMBERED.is_match(cleaned) || !cleaned.contains('?') {
            continue;
        }
        return (cleaned.chars().count() <= MAXIMUM_CHOOSER_QUESTION_CHARACTERS).then(|| cleaned.to_owned());
    }
    None
}

fn last_line(text: &str) -> Option<String> {
    let line = trim_horizontal(lines(text).last()?);
    let readable = !line.is_empty()
        && line.chars().count() <= MAXIMUM_QUESTION_CHARACTERS
        && !line.chars().any(|character| character < ' ' || is_default_ignorable(character));
    readable.then(|| line.to_owned())
}

fn is_default_ignorable(character: char) -> bool {
    matches!(character,
        '\u{AD}' | '\u{34F}' | '\u{61C}' | '\u{115F}'..='\u{1160}' | '\u{17B4}'..='\u{17B5}' | '\u{180B}'..='\u{180F}'
        | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{206F}' | '\u{3164}'
        | '\u{FE00}'..='\u{FE0F}' | '\u{FEFF}' | '\u{FFA0}')
}

fn detect(raw: &str) -> Option<TerminalAttentionKind> {
    let lowered = plain(raw).to_lowercase();
    let start = lowered.char_indices().rev().nth(CANDIDATE_CHARACTERS - 1).map_or(0, |(index, _)| index);
    let candidate = &lowered[start..];

    if PASSWORD.is_match(candidate) {
        return Some(TerminalAttentionKind::Password);
    }
    if CONVENTIONAL.iter().any(|conventional| conventional.is_match(candidate)) {
        return Some(TerminalAttentionKind::Confirmation);
    }
    // Claude Code paints a multi-line chooser rather than ending in `[y/n]`: a question plus a marked row and another
    // numbered row is an interaction, not ordinary command output.
    let all: Vec<&str> = lines(candidate).collect();
    let has_question = all.iter().any(|line| line.contains('?'));
    let has_selected = all.iter().any(|line| SELECTED_CHOICE.is_match(line));
    let choices = all.iter().filter(|line| ANY_CHOICE.is_match(line)).count();
    (has_question && has_selected && choices >= 2).then_some(TerminalAttentionKind::Confirmation)
}

#[cfg(test)]
mod tests;
