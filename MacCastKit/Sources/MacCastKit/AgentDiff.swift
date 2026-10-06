import Foundation

/// Turns a tool's own description of a change into lines a card can draw.
///
/// Not a diff algorithm: Claude Code hands over the fragment it replaces (`old_string` and
/// `new_string`), so there is nothing to align. What this adds is the two things a reader needs
/// and the raw strings do not say: which file, and which side each line belongs to.
public enum AgentDiff {
    /// A replacement, as `-` lines and `+` lines under the file it happens in.
    ///
    /// Truncated like any other card content, with the cut declared rather than silent: a
    /// three-thousand-line rewrite is not readable on a phone, and a card that quietly shows the
    /// first two hundred lines is worse than one that says so.
    public static func replacement(
        old: String,
        new: String,
        path: String?,
        limit: Int = AgentLimits.maximumToolOutputBytes
    ) -> String {
        var text = ""
        if let path {
            text += "--- \(path)\n+++ \(path)\n"
        }
        for line in lines(of: old) {
            text += "-" + line + "\n"
        }
        for line in lines(of: new) {
            text += "+" + line + "\n"
        }
        guard text.utf8.count > limit else { return text }
        // Cut on a line boundary, since half a line in a diff reads as a different change.
        var kept = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = kept + line + "\n"
            if next.utf8.count > limit - 64 { break }
            kept = next
        }
        return kept + "… (the rest of this change is not shown)\n"
    }

    private static func lines(of text: String) -> [String] {
        var pieces = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A trailing newline is how a file ends, not a line of its own, so it would draw as an
        // empty `-` or `+` row that is not part of the change.
        if pieces.last == "" { pieces.removeLast() }
        return pieces
    }
}
