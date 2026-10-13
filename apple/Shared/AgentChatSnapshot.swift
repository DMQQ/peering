import Foundation

/// One agent chat as the widget and the Live Activity need it: plain values, since neither process links the app's transcript types.
nonisolated struct AgentChatSnapshot: Codable, Hashable, Identifiable {
    enum State: String, Codable, Hashable {
        case needsYou
        case working
        case finished
        case failed

        /// What a list shows first: the chat that is waiting on the person, then the busy ones.
        var rank: Int {
            switch self {
            case .needsYou: 0
            case .working: 1
            case .failed: 2
            case .finished: 3
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

    /// The chat and Mac a ``url`` names. A link with no valid chat id opens nothing.
    static func parse(_ url: URL) -> (chatID: UUID, hostID: String?)? {
        guard url.scheme == "peering", url.host == "chat",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let chatID = items.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
        else { return nil }
        let hostID = items.first(where: { $0.name == "host" })?.value
        return (chatID, hostID?.isEmpty == false ? hostID : nil)
    }
}

/// What the agent chat card shows. Apart from its attributes so the Mac host, which has no ActivityKit, builds and encodes the same type the widget decodes.
///
/// A push from the Mac leaves the chat's title, folder and activity empty and names the Mac by `hostKey`: the card reads the words from the App Group store.
nonisolated struct AgentChatActivityState: Codable, Hashable {
    /// The chat the card is about: the one waiting on the person, else the busiest.
    var chat: AgentChatSnapshot
    var waiting: Int
    var working: Int
    /// ``HostKey`` of the Mac the chat runs on. Optional so a card started by an earlier build still decodes.
    var hostKey: String?
}
