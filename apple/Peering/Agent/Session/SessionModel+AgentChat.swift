import PeeringKit
import RemoteCore
import SwiftUI

extension SessionModel {
    var availableChatAgents: [TerminalAgent] {
        availableAgents.filter(\.supportsChat)
    }

    var agentSessions: [RemoteAgentSession] { activeSession?.agentSessions ?? [] }

    var agentPicker: AgentPickerState { activeSession?.agentPicker ?? AgentPickerState() }

    var selectedAgentSessionID: UUID? {
        get { activeSession?.selectedAgentSessionID }
        set { activeSession?.selectedAgentSessionID = newValue }
    }

    var selectedAgentSession: RemoteAgentSession? {
        guard let id = activeSession?.selectedAgentSessionID else { return nil }
        return activeSession?.agentSessions.first { $0.id == id }
    }

    /// Written back to nil when taken, so the same arrival is not opened twice.
    var newAgentSessionID: UUID? {
        get { activeSession?.newAgentSessionID }
        set { activeSession?.newAgentSessionID = newValue }
    }

    /// A name typed onto a chat, this phone's own: the Mac's title still says what it runs.
    func renameAgentSession(_ id: UUID, to name: String) {
        guard !name.isEmpty,
              let index = activeSession?.agentSessions.firstIndex(where: { $0.id == id }) else { return }
        activeSession?.agentSessions[index].title = name
    }

    var hasAgentApprovalWaiting: Bool {
        agentSessions.contains { !$0.transcript.pendingApprovals.isEmpty }
    }

    func refreshAgentSessions() { activeSession?.refreshAgentSessions() }

    func startAgentChat(agentID: String, directory: String?) {
        Analytics.featureUsed(.agentChatStarted, agent: agentID)
        activeSession?.startAgentChat(agentID: agentID, directory: directory)
    }

    var hostSupportsAgentPause: Bool { activeSession?.hostSupportsAgentPause ?? false }

    func pauseAgentSession(_ id: UUID) {
        Analytics.featureUsed(.agentChatStopped, agent: agentCards.first { $0.id == id }?.agentID)
        activeSession?.pauseAgentSession(id)
    }

    /// A new chat in the same folder that opens with a recap of one the CLI can no longer reopen.
    func continueInNewChat(from session: RemoteAgentSession) {
        Analytics.featureUsed(.agentChatContinuedInNew, agent: session.agentID)
        ChatSeed.set(AgentRecap.text(from: session.transcript), agentID: session.agentID)
        startAgentChat(agentID: session.agentID, directory: session.directory)
    }

    var hostSupportsAgentSessionImport: Bool { activeSession?.hostSupportsAgentSessionImport ?? false }

    var resumableSessions: [AgentResumableSession]? { activeSession?.resumableSessions }

    func refreshResumableSessions() { activeSession?.refreshResumableSessions() }

    func resumeAgentSession(_ session: AgentResumableSession) {
        Analytics.featureUsed(.agentChatResumed, agent: session.agentID)
        activeSession?.resumeAgentSession(session)
    }

    func sendAgentPrompt(_ text: String, to id: UUID) {
        Analytics.featureUsed(.agentPromptSent, agent: agentCards.first { $0.id == id }?.agentID)
        activeSession?.sendAgentPrompt(text, to: id)
    }

    func respondToAgentApproval(_ approvalID: String, decision: AgentApprovalDecision, in id: UUID) {
        activeSession?.respondToAgentApproval(approvalID, decision: decision, in: id)
    }

    var agentCards: [AgentCardDigest] { activeSession?.agentCards ?? [] }

    func ensureAgentHistory(_ id: UUID) { activeSession?.ensureAgentHistory(id) }

    func agentQueue(for id: UUID) -> [String] { activeSession?.agentQueues[id]?.prompts ?? [] }

    func removeQueuedAgentPrompt(at offset: Int, in id: UUID) { activeSession?.removeQueuedAgentPrompt(at: offset, in: id) }

    func interruptAgent(_ id: UUID) { activeSession?.interruptAgent(id) }

    func setAgentModel(_ model: String?, in id: UUID) { activeSession?.setAgentModel(model, in: id) }

    var hostSupportsAgentModelPicker: Bool { activeSession?.hostSupportsAgentModelPicker ?? false }

    func setAgentPermissionMode(_ mode: AgentPermissionMode, in id: UUID) {
        activeSession?.setAgentPermissionMode(mode, in: id)
    }

    var hostSupportsAgentPermissionModes: Bool { activeSession?.hostSupportsAgentPermissionModes ?? false }

    var hostSupportsAgentUsage: Bool { activeSession?.hostSupportsAgentUsage ?? false }

    func ensureAgentPreviews() { activeSession?.ensureAgentPreviews() }

    /// Moves a chat with a conversation to History and deletes one without, so ending a chat does not lose what was said in it.
    func endAgentSession(_ id: UUID) {
        let session = agentSessions.first { $0.id == id }
        let action = AgentEndAction.choose(
            hasConversation: session.map { !$0.transcript.isEmpty } ?? false,
            isWorking: session?.state == .working,
            isPaused: session.map { AgentPause.isPaused($0.transcript) } ?? false,
            hostSupportsPause: hostSupportsAgentPause
        )
        switch action {
        case .pause: pauseAgentSession(id)
        case .close: closeAgentSession(id)
        }
    }

    func closeAgentSession(_ id: UUID) {
        LastActivity.clear(id)
        activeSession?.closeAgentSession(id)
    }

    func closeAgentSessionIfUnused(_ id: UUID) { activeSession?.closeAgentSessionIfUnused(id) }

    func browseAgentFolder(_ path: String?) { activeSession?.browseAgentFolder(path) }
}
