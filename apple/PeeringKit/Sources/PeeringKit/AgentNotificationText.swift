import Foundation

/// The words of the pushes an agent chat sends when the phone is away.
public enum AgentNotificationText {
    public static func approval(
        agentName: String,
        reason: String?,
        detail: String?,
        words: AgentNotificationWords = .english
    ) -> (title: String, body: String) {
        (
            words.asks(agentName),
            AgentApprovalNotification.truncated(AgentApprovalBody.text(command: detail, reason: reason) ?? "").nonEmpty
                ?? words.needsApproval
        )
    }

    public static func finished(
        agentName: String,
        ok: Bool,
        stopped: Bool,
        lastReply: String?,
        editedFiles: Int = 0,
        duration: TimeInterval? = nil,
        words: AgentNotificationWords = .english
    ) -> (title: String, body: String) {
        let outcome: AgentNotificationWords.Outcome = ok ? .finished : (stopped ? .stopped : .failed)
        let detail = AgentTurnDigest.detail(editedFiles: editedFiles, duration: duration, words: words)
        let headline: String
        if let lastReply, !lastReply.isEmpty {
            let firstLine = lastReply.split(separator: "\n").first.map(String.init) ?? lastReply
            headline = String(firstLine.prefix(140))
        } else {
            headline = words.turn(outcome)
        }
        return (words.title(agentName, outcome), detail.map { "\(headline)\n\($0)" } ?? headline)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
