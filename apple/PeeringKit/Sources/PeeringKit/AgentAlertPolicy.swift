import Foundation

/// Which agent alerts reach the person while they are away, under the "Notify me only for decisions" setting.
public enum AgentAlertPolicy {
    public enum Alert: Equatable, Sendable {
        /// An approval or a question: the agent cannot go on without the person.
        case decision
        case finished
        case failed
    }

    public static func allows(_ alert: Alert, decisionsOnly: Bool) -> Bool {
        alert == .decision || !decisionsOnly
    }
}
