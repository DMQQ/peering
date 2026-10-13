import Foundation

/// A card the Mac pushed carries ids and states, not words. The words come from what the app wrote to the App Group store, matched by chat id and by ``HostKey``.
extension SessionActivityState {
    var shownHostName: String {
        if let hostName { return hostName }
        let known = SharedStore.knownMacs.first { hostKey != nil && HostKey.of($0.id) == hostKey }
        return known?.name ?? String(localized: "Mac")
    }
}

extension AgentChatActivityState {
    /// The chat with the words the app knows filled in, and the Mac it runs on found, so the card names the chat and its tap opens it.
    var resolvedChat: AgentChatSnapshot {
        var resolved = chat
        let stored = SharedStore.agentChats.first { $0.id == chat.id }
        if resolved.title.isEmpty { resolved.title = stored?.title ?? "" }
        if resolved.folder.isEmpty { resolved.folder = stored?.folder ?? "" }
        if resolved.hostID == nil {
            resolved.hostID = stored?.hostID ?? knownMac?.id
        }
        if resolved.title.isEmpty {
            resolved.title = knownMac?.name ?? String(localized: "Coding agent")
        }
        return resolved
    }

    private var knownMac: SharedStore.KnownMac? {
        guard let hostKey else { return nil }
        return SharedStore.knownMacs.first { HostKey.of($0.id) == hostKey }
    }
}
