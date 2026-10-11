//! The events a chat keeps, so a client that comes back can ask for what it missed.

use peering_wire::agent::{AgentStreamEvent, AgentStreamPayload};

pub const MAXIMUM_TRANSCRIPT_BYTES: usize = 512 * 1024;
pub const MAXIMUM_REPLAY_EVENTS: usize = 200;
pub const REPLAY_CHUNK_BYTES: usize = 64 * 1024;
/// What a payload that is not text counts for, so the budget sees every event.
const FIXED_PAYLOAD_BYTES: usize = 64;

#[derive(Debug)]
pub struct TranscriptLog {
    events: Vec<AgentStreamEvent>,
    next_index: u64,
    bytes: usize,
    truncated_at_front: bool,
}

impl Default for TranscriptLog {
    fn default() -> Self {
        Self::new()
    }
}

impl TranscriptLog {
    pub fn new() -> Self {
        Self {
            events: Vec::new(),
            next_index: 1,
            bytes: 0,
            truncated_at_front: false,
        }
    }

    /// The index of the newest event, or 0 when there is none.
    pub fn last_index(&self) -> u64 {
        self.next_index - 1
    }

    pub fn truncated_at_front(&self) -> bool {
        self.truncated_at_front
    }

    pub fn has_prompt(&self) -> bool {
        self.events
            .iter()
            .any(|event| matches!(event.payload, AgentStreamPayload::UserPrompt { .. }))
    }

    pub fn last_payload(&self) -> Option<&AgentStreamPayload> {
        self.events.last().map(|event| &event.payload)
    }

    pub fn append(&mut self, payload: AgentStreamPayload) -> AgentStreamEvent {
        // A reply's final text replaces the deltas that built it, so replay does not send the text twice.
        if matches!(payload, AgentStreamPayload::TextFinal { .. }) {
            self.drop_trailing_deltas();
        }
        let event = AgentStreamEvent {
            index: self.next_index,
            payload,
        };
        self.next_index += 1;
        self.bytes += approximate_bytes(&event.payload);
        self.events.push(event.clone());
        self.trim();
        event
    }

    /// The events after `since`, split so that no chunk passes the event or byte budget.
    pub fn chunks(&self, since: u64) -> Vec<Vec<AgentStreamEvent>> {
        let mut chunks: Vec<Vec<AgentStreamEvent>> = Vec::new();
        let mut current: Vec<AgentStreamEvent> = Vec::new();
        let mut size = 0;
        for event in self.events.iter().filter(|event| event.index > since) {
            let event_size = approximate_bytes(&event.payload);
            let full = current.len() >= MAXIMUM_REPLAY_EVENTS || size + event_size > REPLAY_CHUNK_BYTES;
            if !current.is_empty() && full {
                chunks.push(std::mem::take(&mut current));
                size = 0;
            }
            current.push(event.clone());
            size += event_size;
        }
        if !current.is_empty() {
            chunks.push(current);
        }
        chunks
    }

    fn drop_trailing_deltas(&mut self) {
        while matches!(
            self.events.last(),
            Some(AgentStreamEvent {
                payload: AgentStreamPayload::TextDelta { .. },
                ..
            })
        ) {
            if let Some(removed) = self.events.pop() {
                self.bytes = self.bytes.saturating_sub(approximate_bytes(&removed.payload));
            }
        }
    }

    /// Whole turns go first, oldest first. A single turn that is still too big keeps its shape and loses its tool
    /// output instead.
    fn trim(&mut self) {
        while self.bytes > MAXIMUM_TRANSCRIPT_BYTES {
            let Some(cut) = self.second_turn_start() else {
                break;
            };
            let removed: usize = self.events[..cut].iter().map(|event| approximate_bytes(&event.payload)).sum();
            self.events.drain(..cut);
            self.bytes = self.bytes.saturating_sub(removed);
            self.truncated_at_front = true;
        }
        for event in self.events.iter_mut() {
            if self.bytes <= MAXIMUM_TRANSCRIPT_BYTES {
                break;
            }
            if let AgentStreamPayload::ToolFinished { output, truncated, .. } = &mut event.payload {
                if let Some(kept) = output.take() {
                    self.bytes = self.bytes.saturating_sub(kept.len());
                    *truncated = true;
                }
            }
        }
    }

    fn second_turn_start(&self) -> Option<usize> {
        self.events
            .iter()
            .enumerate()
            .filter(|(_, event)| matches!(event.payload, AgentStreamPayload::UserPrompt { .. }))
            .nth(1)
            .map(|(position, _)| position)
    }
}

fn approximate_bytes(payload: &AgentStreamPayload) -> usize {
    match payload {
        AgentStreamPayload::UserPrompt { text }
        | AgentStreamPayload::TextDelta { text }
        | AgentStreamPayload::TextFinal { text }
        | AgentStreamPayload::Notice { text } => text.len(),
        AgentStreamPayload::Failure { message } => message.len(),
        AgentStreamPayload::ToolStarted { call } => {
            call.detail.as_deref().map_or(0, str::len) + call.diff.as_deref().map_or(0, str::len)
        }
        AgentStreamPayload::ToolFinished { output, .. } => output.as_deref().map_or(0, str::len),
        AgentStreamPayload::Child { event, .. } => approximate_bytes(event),
        AgentStreamPayload::SessionReady { .. }
        | AgentStreamPayload::TurnStarted {}
        | AgentStreamPayload::ApprovalRequested { .. }
        | AgentStreamPayload::ApprovalResolved { .. }
        | AgentStreamPayload::TurnFinished { .. }
        | AgentStreamPayload::SessionExited { .. } => FIXED_PAYLOAD_BYTES,
    }
}
