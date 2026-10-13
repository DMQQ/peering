import Foundation
import MacCastKit
import RemoteCore

extension MacSession {
    func loadAgentChanges(_ id: UUID) {
        agentChangesLoading.insert(id)
        agentChangesAskedAt[id] = MonotonicStamp()
        wire?.sendAgent(.changes(sessionID: id))
    }

    /// Asked ahead of the screen that shows it, so the answer is usually there when the screen opens. Skipped while one is on its way or a recent one is held.
    func prefetchAgentChanges(_ id: UUID, freshFor seconds: TimeInterval = 20) {
        guard !agentChangesLoading.contains(id) else { return }
        if let asked = agentChangesAskedAt[id], asked.isWithin(seconds: seconds) { return }
        loadAgentChanges(id)
    }

    func commitAgentChanges(_ id: UUID, paths: [String], message: String) {
        guard agentGitBusy[id] == nil else { return }
        guard ControlTextPolicy.verdict(forCommitOf: paths, message: message) == .fits else {
            agentGitResults[id] = AgentGitResult(
                operation: .commit,
                succeeded: false,
                message: String(localized: "That commit is too large to send. Choose fewer files or shorten the message.")
            )
            return
        }
        agentGitBusy[id] = .commit
        agentGitResults[id] = nil
        wire?.sendAgent(.commit(sessionID: id, paths: paths, message: message))
    }

    func pushAgentChanges(_ id: UUID) {
        guard agentGitBusy[id] == nil else { return }
        agentGitBusy[id] = .push
        agentGitResults[id] = nil
        wire?.sendAgent(.push(sessionID: id))
    }

    /// The Mac refused a request about this chat: stop the waiting, and say why where the person is looking.
    func clearPendingChangesWork(of id: UUID, because message: String) {
        if agentChangesLoading.remove(id) != nil, agentChanges[id] == nil {
            agentChanges[id] = .failure(message)
        }
        if let operation = agentGitBusy.removeValue(forKey: id) {
            agentGitResults[id] = AgentGitResult(operation: operation, succeeded: false, message: message)
        }
    }
}
