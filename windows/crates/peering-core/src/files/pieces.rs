//! A preview crosses the wire in pieces, because a frame over 64 KiB is dropped by a peer that is still in its handshake
//! limit and base64 makes raw bytes a third larger.

use peering_wire::terminal::TerminalEvent;

use super::preview::RANGE_CHUNK_BYTES;

/// The events to send for `event`: a file preview is split into pieces of at most 32 KiB, every other event goes whole.
pub fn in_pieces(event: TerminalEvent) -> Vec<TerminalEvent> {
    let TerminalEvent::FileContents { session_id, path, kind, offset, total_bytes, data, is_last } = event else {
        return vec![event];
    };
    if data.len() <= RANGE_CHUNK_BYTES {
        return vec![TerminalEvent::FileContents { session_id, path, kind, offset, total_bytes, data, is_last }];
    }
    let pieces = data.chunks(RANGE_CHUNK_BYTES);
    let last = pieces.len() - 1;
    let mut start = offset;
    pieces
        .enumerate()
        .map(|(position, piece)| {
            let event = TerminalEvent::FileContents {
                session_id: session_id.clone(),
                path: path.clone(),
                kind,
                offset: start,
                total_bytes,
                data: piece.to_vec(),
                is_last: is_last && position == last,
            };
            start += i64::try_from(piece.len()).unwrap_or(0);
            event
        })
        .collect()
}
