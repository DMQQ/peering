import Foundation
import RemoteCore

extension SessionModel {
    func agentChanges(for id: UUID) -> AgentChangesReport? { activeSession?.agentChanges[id] }

    func isLoadingAgentChanges(_ id: UUID) -> Bool { activeSession?.agentChangesLoading.contains(id) ?? false }

    func loadAgentChanges(_ id: UUID) { activeSession?.loadAgentChanges(id) }

    func prefetchAgentChanges(_ id: UUID) { activeSession?.prefetchAgentChanges(id) }

    func agentGitBusy(for id: UUID) -> AgentGitOperation? { activeSession?.agentGitBusy[id] }

    func agentGitResult(for id: UUID) -> AgentGitResult? { activeSession?.agentGitResults[id] }

    func commitAgentChanges(_ id: UUID, paths: [String], message: String) {
        activeSession?.commitAgentChanges(id, paths: paths, message: message)
    }

    func pushAgentChanges(_ id: UUID) { activeSession?.pushAgentChanges(id) }
}
