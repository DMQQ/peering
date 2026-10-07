import Foundation

/// The words of the pushes an agent chat sends when the phone is away.
public enum AgentNotificationText {
    public static func approval(agentName: String, reason: String?, detail: String?) -> (title: String, body: String) {
        ("\(agentName) asks", reason ?? detail ?? "Needs your approval.")
    }

    public static func finished(
        agentName: String,
        ok: Bool,
        stopped: Bool,
        lastReply: String?
    ) -> (title: String, body: String) {
        let outcome = ok ? "finished" : (stopped ? "stopped" : "failed")
        if let lastReply, !lastReply.isEmpty {
            let firstLine = lastReply.split(separator: "\n").first.map(String.init) ?? lastReply
            return ("\(agentName) \(outcome)", String(firstLine.prefix(140)))
        }
        return ("\(agentName) \(outcome)", ok ? "The turn finished." : (stopped ? "The turn was stopped." : "The turn failed."))
    }
}
