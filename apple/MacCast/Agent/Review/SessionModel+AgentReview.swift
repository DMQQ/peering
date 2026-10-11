import MacCastKit
import RemoteCore

extension SessionModel {
    /// Whether the Mac is answering, so a report held for a chat can be called current.
    var isAgentHostReachable: Bool {
        if case .ready = activeSession?.phase { return true }
        return false
    }

    func agentReviewSources() -> [AgentReviewSource] {
        let reachable = isAgentHostReachable
        return agentCards.filter(\.isLive).map { card in
            AgentReviewSource(
                chatID: card.id, title: card.title, directory: card.directory,
                report: agentChanges(for: card.id), isReachable: reachable, isLoading: isLoadingAgentChanges(card.id)
            )
        }
    }
}
