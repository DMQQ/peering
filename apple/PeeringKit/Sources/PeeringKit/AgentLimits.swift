import Foundation

/// The sizes the agent chat holds itself to.
public enum AgentLimits {
    public static let maximumToolOutputBytes = 32 * 1024

    /// How many events one replay chunk carries at most, beside the same byte budget.
    public static let maximumReplayEvents = 200

    /// How much of the conversation the Mac keeps for a phone that comes back.
    public static let maximumTranscriptBytes = 512 * 1024

    /// What a conversation keeps after the system warns about memory.
    public static let memoryPressureTranscriptBytes = 64 * 1024

    /// Text cut to a byte budget, on a character boundary.
    public static func trimmed(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var bytes = text.utf8.prefix(limit)
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes = bytes.dropLast()
        }
        return (String(decoding: bytes, as: UTF8.self), true)
    }
}
