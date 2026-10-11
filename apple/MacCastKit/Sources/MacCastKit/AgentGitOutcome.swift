import Foundation
import RemoteCore

/// Turns what git printed into the one result the phone shows.
public enum AgentGitOutcome {
    public static let maximumMessageLength = 1_200

    public static func result(operation: AgentGitOperation, succeeded: Bool, output: String) -> AgentGitResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if succeeded {
            let fallback = operation == .commit ? "Committed." : "Pushed."
            return AgentGitResult(operation: operation, succeeded: true, message: text.isEmpty ? fallback : head(text))
        }
        var message = text.isEmpty ? "git stopped without saying why. It may have run out of time." : tail(text)
        if let hint = hint(for: text) { message = hint + "\n\n" + message }
        return AgentGitResult(operation: operation, succeeded: false, message: message)
    }

    public static func refused(_ operation: AgentGitOperation, _ reason: AgentGitRefusal) -> AgentGitResult {
        AgentGitResult(operation: operation, succeeded: false, message: reason.text)
    }

    /// The end of the output, where git states its error and a hook has printed its chatter first.
    private static func tail(_ text: String) -> String {
        text.count <= maximumMessageLength ? text : "…" + text.suffix(maximumMessageLength)
    }

    private static func head(_ text: String) -> String {
        text.count <= maximumMessageLength ? text : text.prefix(maximumMessageLength) + "…"
    }

    private static func hint(for text: String) -> String? {
        let lowered = text.lowercased()
        let signs = [
            "could not read username", "could not read password", "authentication failed",
            "permission denied (publickey", "terminal prompts disabled",
        ]
        guard signs.contains(where: lowered.contains) else { return nil }
        return "The Mac has no saved credential for this remote, and git cannot ask for one from here."
    }
}
