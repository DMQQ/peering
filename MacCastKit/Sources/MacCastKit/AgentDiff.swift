import Foundation

public enum AgentDiff {
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
        if pieces.last == "" { pieces.removeLast() }
        return pieces
    }
}
