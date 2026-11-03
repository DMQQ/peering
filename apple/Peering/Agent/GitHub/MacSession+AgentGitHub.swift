import Foundation
import RemoteCore

extension MacSession {
    func loadAgentGitHub(_ id: UUID) {
        guard hostSupportsAgentGitHub else { return }
        wire?.sendAgent(.github(sessionID: id))
    }

    func performAgentGitHub(_ action: AgentGitHubAction, for id: UUID) {
        guard hostSupportsAgentGitHub, agentGitHubBusy[id] == nil else { return }
        agentGitHubBusy[id] = action
        agentGitHubResults[id] = nil
        wire?.sendAgent(.githubAction(sessionID: id, action: action))
    }
}

extension SessionModel {
    var hostSupportsAgentGitHub: Bool { activeSession?.hostSupportsAgentGitHub ?? false }

    func agentGitHub(for id: UUID) -> AgentGitHubReport? { activeSession?.agentGitHub[id] }

    func agentGitHubBusy(for id: UUID) -> AgentGitHubAction? { activeSession?.agentGitHubBusy[id] }

    func agentGitHubResult(for id: UUID) -> AgentGitHubResult? { activeSession?.agentGitHubResults[id] }

    func loadAgentGitHub(_ id: UUID) { activeSession?.loadAgentGitHub(id) }

    func performAgentGitHub(_ action: AgentGitHubAction, for id: UUID) { activeSession?.performAgentGitHub(action, for: id) }
}
