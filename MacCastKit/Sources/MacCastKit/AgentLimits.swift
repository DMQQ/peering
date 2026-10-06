import Foundation

/// The sizes the agent chat holds itself to.
///
/// One place because two producers trim: the host trims what it puts on the wire, and the phone
/// trims what it keeps. A number written twice is a number that drifts.
public enum AgentLimits {
    /// How much of one tool result travels, and how much of one text block.
    ///
    /// The control channel accepts 64 KB and a `Data` is base64 in JSON, so 32 KB of text is some
    /// 43 KB of payload: comfortably inside the cap with room for the envelope. What is cut is
    /// said to be cut, both on the wire (``AgentStreamEvent/Payload/toolFinished(callID:ok:output:truncated:)``)
    /// and on the card.
    public static let maximumToolOutputBytes = 32 * 1024

    /// How many events one replay chunk carries at most, beside the same byte budget.
    public static let maximumReplayEvents = 200

    /// How much of the conversation the Mac keeps for a phone that comes back.
    ///
    /// The terminal's history size, for the same reason: a buffer that only grows is a Mac that
    /// runs out of memory for a session nobody is reading. Trimmed at turn boundaries, never
    /// mid-turn, so a card's start and its result are never separated.
    public static let maximumTranscriptBytes = 512 * 1024

    /// Text cut to a byte budget, on a character boundary.
    ///
    /// The count is bytes and the cut is not: a CLI's output is UTF-8, and a cut inside a scalar
    /// leaves a replacement character where a letter was. The returned flag is what both ends say
    /// out loud rather than showing half an answer as if it were whole.
    public static func trimmed(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var bytes = text.utf8.prefix(limit)
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes = bytes.dropLast()
        }
        return (String(decoding: bytes, as: UTF8.self), true)
    }
}
