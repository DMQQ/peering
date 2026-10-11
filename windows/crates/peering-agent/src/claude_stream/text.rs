//! Text shaping for what the phone shows: byte-limited cuts, tool result text, and the edit diff.

use super::json::{object_array, str_field};
use serde_json::Value;

pub const MAXIMUM_TOOL_OUTPUT_BYTES: usize = 32 * 1024;

const PICTURE_PLACEHOLDER: &str = "[a picture, not shown here]";
const DIFF_TRUNCATED_NOTE: &str = "… (the rest of this change is not shown)\n";

/// Cuts `text` to at most `limit` bytes on a character boundary.
pub fn trimmed(text: &str, limit: usize) -> (String, bool) {
    if text.len() <= limit {
        return (text.to_owned(), false);
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (text[..end].to_owned(), true)
}

/// A tool result's content is a string or a list of blocks; a picture in the list has no text here.
pub fn content_text(content: Option<&Value>) -> String {
    if let Some(string) = content.and_then(Value::as_str) {
        return string.to_owned();
    }
    let Some(blocks) = object_array(content) else {
        return String::new();
    };
    let mut parts: Vec<String> = Vec::new();
    for block in blocks {
        match block.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(text) = str_field(block, "text") {
                    parts.push(text);
                }
            }
            Some("image") => parts.push(PICTURE_PLACEHOLDER.to_owned()),
            _ => {}
        }
    }
    parts.join("\n")
}

/// The unified diff of one replacement, cut to the tool output budget.
pub fn replacement_diff(old: &str, new: &str, path: Option<&str>) -> String {
    let mut text = String::new();
    if let Some(path) = path {
        text.push_str(&format!("--- {path}\n+++ {path}\n"));
    }
    for line in lines_of(old) {
        text.push_str(&format!("-{line}\n"));
    }
    for line in lines_of(new) {
        text.push_str(&format!("+{line}\n"));
    }
    if text.len() <= MAXIMUM_TOOL_OUTPUT_BYTES {
        return text;
    }
    let mut kept = String::new();
    for line in text.split('\n') {
        let next = format!("{kept}{line}\n");
        if next.len() > MAXIMUM_TOOL_OUTPUT_BYTES - 64 {
            break;
        }
        kept = next;
    }
    kept + DIFF_TRUNCATED_NOTE
}

fn lines_of(text: &str) -> Vec<&str> {
    let mut pieces: Vec<&str> = text.split('\n').collect();
    if pieces.last() == Some(&"") {
        pieces.pop();
    }
    pieces
}
