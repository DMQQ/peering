import Foundation
import MacCastKit
import RemoteCore
import SwiftUI

struct AgentPickerState {
    var path: String?
    var startPath: String?
    var entries: [RemoteDirectoryEntry] = []
    var isLoading = false
    var failure: String?
    /// Why the Mac is slow to answer, while the request is still outstanding.
    var waitingNote: String?
}

/// Agent chats mirror ``MacSession+Terminal``: reattached from a listing, replayed, owner-scoped on the Mac, forgotten when the session is gone. A listing carries no conversation, so history is asked lazily and each session remembers how far it has read.
extension MacSession {
    // MARK: - Requests

    func refreshAgentSessions() {
        guard hostSupportsAgentChat else { return }
        wire?.sendAgent(.list)
    }

    /// `since` is the highest index applied, so a reattach fetches only what was missed; a never-read session asks from zero.
    func loadAgentHistory(_ id: UUID, since: UInt64) {
        wire?.sendAgent(.history(sessionID: id, since: since))
    }

    /// A chat the Mac already had when this phone connected is listed but empty: nothing else asks for its conversation.
    func ensureAgentHistory(_ id: UUID) {
        guard let session = agentSessions.first(where: { $0.id == id }),
              !session.isLoaded, agentHistoryRequested.insert(id).inserted
        else { return }
        loadAgentHistory(id, since: 0)
    }

    func startAgentChat(agentID: String, directory: String?) {
        AgentFolderHistory.record(directory: directory, agentID: agentID, macName: model.hostName)
        wire?.sendAgent(.start(agentID: agentID, directory: directory))
    }

    /// The transcript's copy arrives from the Mac, so nothing is optimistic here.
    func sendAgentPrompt(_ text: String, to id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var state: AgentSessionState?
        if let index = agentSessions.firstIndex(where: { $0.id == id }) {
            agentSessions[index].failure = nil
            state = agentSessions[index].transcript.state
        }
        var queue = agentQueues[id] ?? AgentPromptQueue()
        let submission = queue.submit(trimmed, sessionState: state)
        agentQueues[id] = queue.prompts.isEmpty ? nil : queue
        if submission == .send {
            wire?.sendAgent(.prompt(sessionID: id, text: trimmed))
        }
    }

    func refreshAgentCards() {
        #if DEBUG
        if AgentSeed.isRequested, !agentSessions.contains(where: { AgentSeed.owns($0.id) }) {
            agentSessions = AgentSeed.sessions() + agentSessions
        }
        #endif
        agentCardsTask?.cancel()
        agentCardsTask = nil
        let cards = agentSessions.map(AgentCardDigest.init)
        if cards != agentCards { agentCards = cards }
    }

    /// Trailing, not leading: a burst of tokens becomes one rebuild after it settles a little, and the card still reads current within a blink.
    func scheduleAgentCards() {
        guard agentCardsTask == nil else { return }
        agentCardsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.refreshAgentCards()
        }
    }

    func removeQueuedAgentPrompt(at offset: Int, in id: UUID) {
        guard var queue = agentQueues[id] else { return }
        queue.remove(at: offset)
        agentQueues[id] = queue.prompts.isEmpty ? nil : queue
    }

    func flushAgentQueue(_ id: UUID, state: AgentSessionState) {
        guard var queue = agentQueues[id] else { return }
        let release = queue.release(state: state)
        agentQueues[id] = queue.prompts.isEmpty ? nil : queue
        if case .send(let text) = release {
            wire?.sendAgent(.prompt(sessionID: id, text: text))
        }
    }

    func respondToAgentApproval(_ approvalID: String, decision: AgentApprovalDecision, in id: UUID) {
        wire?.sendAgent(.approval(sessionID: id, approvalID: approvalID, decision: decision))
    }

    func interruptAgent(_ id: UUID) {
        wire?.sendAgent(.interrupt(sessionID: id))
    }

    func setAgentModel(_ model: String?, in id: UUID) {
        wire?.sendAgent(.setModel(sessionID: id, model: model))
    }

    /// How freely the session may act from now on. The mode shown changes when the Mac confirms it.
    func setAgentPermissionMode(_ mode: AgentPermissionMode, in id: UUID) {
        guard hostSupportsAgentPermissionModes else { return }
        wire?.sendAgent(.setPermissionMode(sessionID: id, mode: mode))
    }

    func closeAgentSession(_ id: UUID) {
        wire?.sendAgent(.close(sessionID: id))
    }

    func browseAgentFolder(_ path: String?) {
        agentPicker.isLoading = true
        agentPicker.waitingNote = nil
        agentPicker.failure = nil
        wire?.sendAgent(.browse(path: path))
    }
}
