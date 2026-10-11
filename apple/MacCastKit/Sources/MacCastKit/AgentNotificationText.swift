import Foundation

/// The words of the pushes an agent chat sends when the phone is away.
public enum AgentNotificationText {
    public static func approval(agentName: String, reason: String?, detail: String?) -> (title: String, body: String) {
        ("\(agentName) asks", AgentApprovalNotification.truncated(AgentApprovalBody.text(command: detail, reason: reason) ?? "").nonEmpty ?? "Needs your approval.")
    }

    public static func finished(
        agentName: String,
        ok: Bool,
        stopped: Bool,
        lastReply: String?,
        editedFiles: Int = 0,
        duration: TimeInterval? = nil
    ) -> (title: String, body: String) {
        let outcome = ok ? "finished" : (stopped ? "stopped" : "failed")
        let detail = AgentTurnDigest.detail(editedFiles: editedFiles, duration: duration)
        let headline: String
        if let lastReply, !lastReply.isEmpty {
            let firstLine = lastReply.split(separator: "\n").first.map(String.init) ?? lastReply
            headline = String(firstLine.prefix(140))
        } else {
            headline = ok ? "The turn finished." : (stopped ? "The turn was stopped." : "The turn failed.")
        }
        return ("\(agentName) \(outcome)", detail.map { "\(headline)\n\($0)" } ?? headline)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
