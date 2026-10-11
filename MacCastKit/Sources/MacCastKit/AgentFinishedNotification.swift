import Foundation

/// The buttons on the notification that says an agent finished a turn, and what each one sends back as the next prompt.
public enum AgentFinishedNotification {
    /// Named by the Mac in the push, and registered by the phone: the relay forwards only categories it knows.
    public static let category = "peering.agent.finished"
    public static let continueIdentifier = "continue"
    public static let replyIdentifier = "reply"
    public static let continuePrompt = "Continue"

    /// The prompt a tapped button stands for. Nil for a tap on the body, a dismissal, or a reply with nothing in it.
    public static func prompt(forActionIdentifier identifier: String, userText: String?) -> String? {
        switch identifier {
        case continueIdentifier:
            return continuePrompt
        case replyIdentifier:
            let trimmed = userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }
}
