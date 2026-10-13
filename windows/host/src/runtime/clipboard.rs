//! The clipboard commands. A read runs on the blocking pool with a deadline, because the program that owns the clipboard can
//! take its time; a write is done at once, so a paste sent straight after a push finds what was pushed.

use std::time::Duration;

use peering_core::ports::clipboard::{Clipboard, ClipboardContent};
use peering_core::session::dispatch::{on_assembled_command, DispatchOutcome, ReadyOutcome};
use peering_wire::chunks::{self, Reassembler, CONTROL_CHUNK_SIZE};
use peering_wire::clipboard::{ClipboardPayload, MAX_IMAGE_BYTES, MAX_REASSEMBLED_BYTES};
use peering_wire::command::RemoteCommand;
use peering_wire::framing::{Frame, MessageKind};
use tokio::task::spawn_local;

use super::connection::{Connection, Flow};
use super::outbound::FrameSender;
use super::refusal::{notice_for_text, Refusal};
use crate::strings;

const READ_DEADLINE: Duration = Duration::from_secs(3);

pub(super) fn new_reassembler() -> Reassembler {
    Reassembler::new(MAX_REASSEMBLED_BYTES)
}

impl Connection {
    /// Carries out a clipboard command the dispatcher handed back.
    pub(super) fn host_command(&mut self, command: RemoteCommand) {
        match command {
            RemoteCommand::RequestClipboard {} => self.answer_clipboard_request(),
            RemoteCommand::PushClipboard { text } => self.write_clipboard(ClipboardContent::Text(text)),
            RemoteCommand::PushClipboardImage { png } if png.len() <= MAX_IMAGE_BYTES => {
                self.write_clipboard(ClipboardContent::Image(png));
            }
            _ => {}
        }
    }

    /// A chunk of a message too large for one frame. Only a command can arrive this way, and it is run once whole.
    pub(super) fn clipboard_chunk(&mut self, frame: &Frame) -> Flow {
        let Ok(Some(whole)) = self.clipboard_chunks.ingest(frame) else {
            return Flow::Open;
        };
        let (outcome, failure) = self.dispatch(|context| on_assembled_command(&whole, context));
        debug_assert!(failure.is_none(), "a clipboard command names no capture source");
        match outcome {
            ReadyOutcome::Dispatched(DispatchOutcome::ForHost(command)) => {
                self.host_command(command);
                Flow::Open
            }
            ReadyOutcome::Close(_) => Flow::Closed,
            _ => Flow::Open,
        }
    }

    fn answer_clipboard_request(&mut self) {
        let clipboard = self.shared.lock().clipboard.clone();
        let allow_image = self.client_flags.supports_clipboard_images == Some(true);
        let frame_id = self.next_clipboard_frame_id();
        let outbound = self.outbound.clone();
        spawn_local(async move {
            let read = tokio::task::spawn_blocking(move || read_payload(clipboard.as_ref(), allow_image));
            let payload = match tokio::time::timeout(READ_DEADLINE, read).await {
                Ok(Ok(payload)) => payload,
                Ok(Err(_)) | Err(_) => ClipboardPayload::text(""),
            };
            send_payload(&outbound, &payload, frame_id);
        });
    }

    fn write_clipboard(&mut self, content: ClipboardContent) {
        let clipboard = self.shared.lock().clipboard.clone();
        if clipboard.write(&content).is_err() {
            let now = self.now();
            self.shared.lock().refusal = Some(Refusal::until(notice_for_text(strings::CLIPBOARD_WRITE_FAILED), now));
        }
    }

    fn next_clipboard_frame_id(&mut self) -> u32 {
        self.clipboard_frame_id = self.clipboard_frame_id.wrapping_add(1);
        self.clipboard_frame_id
    }
}

/// What a phone is told for a request: the clipboard's text or picture, or empty text when there is none it can have. Empty
/// text and not silence, so the phone is never left waiting.
fn read_payload(clipboard: &dyn Clipboard, allow_image: bool) -> ClipboardPayload {
    match clipboard.read(allow_image) {
        Ok(ClipboardContent::Text(text)) if text.len() <= MAX_REASSEMBLED_BYTES / 2 => ClipboardPayload::text(text),
        Ok(ClipboardContent::Image(png)) if allow_image && png.len() <= MAX_IMAGE_BYTES => ClipboardPayload::image(png),
        _ => ClipboardPayload::text(""),
    }
}

fn send_payload(outbound: &FrameSender, payload: &ClipboardPayload, frame_id: u32) {
    for frame in payload_frames(payload, frame_id) {
        // A connection that has closed meanwhile has nobody to tell.
        let _queued = outbound.send(frame);
    }
}

/// The frames that carry the payload: one, or chunks of at most 16 KiB when it does not fit.
pub(super) fn payload_frames(payload: &ClipboardPayload, frame_id: u32) -> Vec<Frame> {
    // A derived Serialize over a string and base64 text.
    let json = serde_json::to_vec(payload).expect("a clipboard payload always serialises");
    if json.len() > MAX_REASSEMBLED_BYTES {
        return payload_frames(&ClipboardPayload::text(""), frame_id);
    }
    chunks::encode(MessageKind::ClipboardContent, &json, frame_id, CONTROL_CHUNK_SIZE)
}

#[cfg(test)]
mod tests {
    use peering_core::fakes::clipboard::MemoryClipboard;
    use peering_core::ports::clipboard::ClipboardError;

    use super::*;

    #[test]
    fn short_text_goes_as_one_frame() {
        let frames = payload_frames(&ClipboardPayload::text("hello"), 1);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, MessageKind::ClipboardContent);
    }

    #[test]
    fn long_text_goes_in_chunks_that_reassemble_to_the_same_message() {
        let text = "x".repeat(CONTROL_CHUNK_SIZE * 3);
        let frames = payload_frames(&ClipboardPayload::text(text.clone()), 9);
        assert!(frames.len() > 3);
        assert!(frames.iter().all(|frame| frame.kind == MessageKind::VideoChunk));
        let mut reassembler = new_reassembler();
        let whole = frames.iter().find_map(|frame| reassembler.ingest(frame).expect("a chunk")).expect("the whole message");
        assert_eq!(whole.kind, MessageKind::ClipboardContent);
        let payload: ClipboardPayload = serde_json::from_slice(&whole.payload).expect("the payload decodes");
        assert_eq!(payload, ClipboardPayload::text(text));
    }

    #[test]
    fn a_payload_past_the_reassembly_limit_is_replaced_by_empty_text() {
        let frames = payload_frames(&ClipboardPayload::text("x".repeat(MAX_REASSEMBLED_BYTES)), 1);
        assert_eq!(frames.len(), 1);
        let payload: ClipboardPayload = serde_json::from_slice(&frames[0].payload).expect("the payload decodes");
        assert_eq!(payload, ClipboardPayload::text(""));
    }

    #[test]
    fn a_request_is_answered_with_the_text_on_the_clipboard() {
        let clipboard = MemoryClipboard::holding(ClipboardContent::Text("copied".to_owned()));
        assert_eq!(read_payload(&clipboard, false), ClipboardPayload::text("copied"));
    }

    #[test]
    fn a_picture_goes_only_to_a_phone_that_can_take_one() {
        let clipboard = MemoryClipboard::holding(ClipboardContent::Image(vec![1, 2, 3]));
        assert_eq!(read_payload(&clipboard, true), ClipboardPayload::image(vec![1, 2, 3]));
        assert_eq!(read_payload(&clipboard, false), ClipboardPayload::text(""));
    }

    #[test]
    fn an_empty_or_unreadable_clipboard_is_answered_with_empty_text() {
        let clipboard = MemoryClipboard::default();
        assert_eq!(read_payload(&clipboard, true), ClipboardPayload::text(""));
        clipboard.fail_with(ClipboardError::Busy);
        assert_eq!(read_payload(&clipboard, true), ClipboardPayload::text(""));
    }

    #[test]
    fn a_picture_over_the_limit_is_not_sent() {
        let clipboard = MemoryClipboard::holding(ClipboardContent::Image(vec![0; MAX_IMAGE_BYTES + 1]));
        assert_eq!(read_payload(&clipboard, true), ClipboardPayload::text(""));
    }
}
