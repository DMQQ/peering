import Foundation
import WidgetKit
import RemoteCore

/// Writes the chats to the shared store for the widget and drives the Live Activity from the same list.
///
/// Throttled and de-duplicated: a streaming reply changes the transcript many times a second, and a widget reload is rationed by the system.
@MainActor
final class AgentWidgetPublisher {
    static let shared = AgentWidgetPublisher()

    static let widgetKind = "PeeringAgents"
    private static let minimumGap: TimeInterval = 1

    private var byHost: [String: [AgentChatSnapshot]] = [:]
    private var written: [AgentChatSnapshot] = []
    private var lastWrite: MonotonicStamp?
    private var pending: Task<Void, Never>?

    private init() {}

    func update(hostKey: String, chats: [AgentChatSnapshot]) {
        guard byHost[hostKey] != chats else { return }
        byHost[hostKey] = chats
        schedule()
    }

    /// A Mac that is no longer open has no chats this phone can show.
    func prune(keeping keys: Set<String>) {
        let before = byHost.count
        byHost = byHost.filter { keys.contains($0.key) }
        if byHost.count != before { schedule() }
    }

    private func schedule() {
        guard pending == nil else { return }
        let wait = max(0, Self.minimumGap - (lastWrite?.elapsedSeconds() ?? Self.minimumGap))
        pending = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        pending = nil
        let all = AgentChatSnapshot.ordered(byHost.values.flatMap { $0 })
        lastWrite = MonotonicStamp()
        // The clock alone is not a change: comparing it would rewrite the store on every token.
        guard all.map(\.withoutClock) != written.map(\.withoutClock) else { return }
        written = all
        SharedStore.agentChats = all
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        AgentChatActivity.shared.update(chats: all)
    }
}
