import ActivityKit
import Foundation

/// One agent chat as the widget and the Live Activity need it: plain values, since neither process links the app's transcript types.
nonisolated struct AgentChatSnapshot: Codable, Hashable, Identifiable {
    enum State: String, Codable, Hashable {
        case needsYou
        case working
        case ready
        case failed

        /// What a list shows first: the chat that is waiting on the person, then the busy ones.
        var rank: Int {
            switch self {
            case .needsYou: 0
            case .working: 1
            case .failed: 2
            case .ready: 3
            }
        }
    }

    var id: String
    var hostID: String?
    var title: String
    var symbol: String
    var folder: String
    var state: State
    var activity: String?
    var planDone: Int
    var planTotal: Int
    var planStepNumber: Int?
    var planStep: String?
    var updatedAt: Date

    var hasUnfinishedPlan: Bool { planTotal > 0 && planDone < planTotal }

    static func ordered(_ chats: [AgentChatSnapshot]) -> [AgentChatSnapshot] {
        chats.sorted {
            $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank : $0.updatedAt > $1.updatedAt
        }
    }

    /// The same chat with the clock ignored, so a write that changed nothing a person can see is skipped.
    var withoutClock: AgentChatSnapshot {
        var copy = self
        copy.updatedAt = .distantPast
        return copy
    }

    /// Opens the chat: the app answers `peering://chat`, connecting to the Mac first when it has to.
    var url: URL {
        var components = URLComponents()
        components.scheme = "peering"
        components.host = "chat"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
            + (hostID.map { [URLQueryItem(name: "host", value: $0)] } ?? [])
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

nonisolated struct AgentChatActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The chat the card is about: the one waiting on the person, else the busiest.
        var chat: AgentChatSnapshot
        var waiting: Int
        var working: Int
    }
}
