import Foundation

/// A passage from the conversation put at the head of the next message as a Markdown quote, so it can be answered without being copied by hand.
public enum AgentCitation {
    private static let longest = 1_200

    /// The quote goes after whatever is already typed, with the caret left on a blank line below it.
    public static func append(_ passage: String, to draft: String) -> String {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return draft }
        let clipped = trimmed.count > longest ? String(trimmed.prefix(longest)) + "…" : trimmed
        let quote = clipped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (typed.isEmpty ? "" : typed + "\n\n") + quote + "\n\n"
    }
}
