//! Keeps one stream event under the 64 KiB control frame rule. A reply or tool output past the budget is cut with a
//! marker, because an event cannot be split across frames.

use peering_wire::agent::AgentStreamPayload;

/// Encoded bytes one event may take, leaving room for the replay or stream wrapper around it.
const MAXIMUM_EVENT_BYTES: usize = 48 * 1024;
const CUT_MARKER: &str = "\n[cut: too long to send]";

pub fn fitted(payload: AgentStreamPayload) -> AgentStreamPayload {
    if encoded_bytes(&payload) <= MAXIMUM_EVENT_BYTES {
        return payload;
    }
    match payload {
        AgentStreamPayload::UserPrompt { text } => cut_text(text, |text| AgentStreamPayload::UserPrompt { text }),
        AgentStreamPayload::TextDelta { text } => cut_text(text, |text| AgentStreamPayload::TextDelta { text }),
        AgentStreamPayload::TextFinal { text } => cut_text(text, |text| AgentStreamPayload::TextFinal { text }),
        AgentStreamPayload::Notice { text } => cut_text(text, |text| AgentStreamPayload::Notice { text }),
        AgentStreamPayload::Failure { message } => {
            cut_text(message, |message| AgentStreamPayload::Failure { message })
        }
        AgentStreamPayload::ToolFinished { call_id, ok, output: Some(output), .. } => cut_text(output, |output| {
            AgentStreamPayload::ToolFinished { call_id: call_id.clone(), ok, output: Some(output), truncated: true }
        }),
        AgentStreamPayload::ToolStarted { mut call } => {
            call.diff = None;
            call.detail = call.detail.map(|detail| cut(&detail, 4 * 1024));
            AgentStreamPayload::ToolStarted { call }
        }
        AgentStreamPayload::Child { parent_call_id, event } => {
            AgentStreamPayload::Child { parent_call_id, event: Box::new(fitted(*event)) }
        }
        other => other,
    }
}

fn cut_text(text: String, rebuild: impl Fn(String) -> AgentStreamPayload) -> AgentStreamPayload {
    let mut keep = text.len();
    loop {
        keep /= 2;
        let candidate = rebuild(cut(&text, keep));
        if keep == 0 || encoded_bytes(&candidate) <= MAXIMUM_EVENT_BYTES {
            return candidate;
        }
    }
}

fn cut(text: &str, keep: usize) -> String {
    let mut end = keep.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{CUT_MARKER}", &text[..end])
}

fn encoded_bytes(payload: &AgentStreamPayload) -> usize {
    serde_json::to_vec(payload).map_or(0, |encoded| encoded.len())
}
