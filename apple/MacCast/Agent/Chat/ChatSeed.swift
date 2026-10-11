import Foundation

/// The opening message waiting for the next new chat: set when one chat stands in for another that could not be reopened, taken by the chat that opens.
@MainActor
enum ChatSeed {
    private static var pending: (text: String, agentID: String, setAt: Date)?
    /// Long enough to cross the Mac creating the chat; past it the seed belongs to nothing.
    private static let lifetime: TimeInterval = 60

    static func set(_ text: String?, agentID: String) {
        pending = text.map { ($0, agentID, Date()) }
    }

    static func take(agentID: String) -> String? {
        defer { pending = nil }
        guard let pending, pending.agentID == agentID, Date().timeIntervalSince(pending.setAt) < lifetime else { return nil }
        return pending.text
    }
}
