import MacCastKit
import RemoteCore
import SwiftUI

extension SessionModel {
    var availableChatAgents: [TerminalAgent] {
        availableAgents.filter(\.supportsChat)
    }

    /// The agent's own CLI stays free in the terminal on every plan; `agentChat` buys this screen.
    var canOpenAgentChat: Bool {
        (activeSession?.hostSupportsAgentChat ?? false) && storeManager.access.includes(.agentChat)
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
        activeSession?.startAgentChat(agentID: agentID, directory: directory)
    }

    func sendAgentPrompt(_ text: String, to id: UUID) { activeSession?.sendAgentPrompt(text, to: id) }

    func respondToAgentApproval(_ approvalID: String, decision: AgentApprovalDecision, in id: UUID) {
        activeSession?.respondToAgentApproval(approvalID, decision: decision, in: id)
    }

    func interruptAgent(_ id: UUID) { activeSession?.interruptAgent(id) }

    func setAgentModel(_ model: String?, in id: UUID) { activeSession?.setAgentModel(model, in: id) }

    var hostSupportsAgentModelPicker: Bool { activeSession?.hostSupportsAgentModelPicker ?? false }

    func setAgentPermissionMode(_ mode: AgentPermissionMode, in id: UUID) {
        activeSession?.setAgentPermissionMode(mode, in: id)
    }

    var hostSupportsAgentPermissionModes: Bool { activeSession?.hostSupportsAgentPermissionModes ?? false }

    var hostSupportsAgentUsage: Bool { activeSession?.hostSupportsAgentUsage ?? false }

    func closeAgentSession(_ id: UUID) { activeSession?.closeAgentSession(id) }

    func browseAgentFolder(_ path: String?) { activeSession?.browseAgentFolder(path) }
}
