import MacCastKit
import RemoteCore
import SwiftUI

/// Agent chats on the root model: the forwarders the panels call, and the two questions the
/// entry points ask.
///
/// An extension rather than lines in `SessionModel.swift`, which is the app's god object and
/// grows every time a feature adds a namespace to it. This is the same pattern the ``MacSession``
/// extensions already use, applied where the settings live.
extension SessionModel {
    /// The agents to offer for a chat: the chat-capable ones the Mac has, once it has said.
    var availableChatAgents: [TerminalAgent] {
        availableAgents.filter(\.supportsChat)
    }

    /// Whether a chat can be started at all: the Mac has said it can, and the plan includes the
    /// screen. The agent's own CLI stays free in the terminal on every plan; what
    /// ``PlanCapability/agentChat`` buys is this screen.
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

    /// The chat the Mac has just opened, which the terminals panel moves to. Written back to nil
    /// when taken, so the same arrival is not opened twice.
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

    /// Whether a chat has an approval waiting, anywhere: what the chrome's dot badge reads.
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

    /// Changes which model a chat runs. Offered only where the Mac has said it can: see
    /// ``MacSession/hostSupportsAgentModelPicker``.
    func setAgentModel(_ model: String?, in id: UUID) { activeSession?.setAgentModel(model, in: id) }

    var hostSupportsAgentModelPicker: Bool { activeSession?.hostSupportsAgentModelPicker ?? false }

    func closeAgentSession(_ id: UUID) { activeSession?.closeAgentSession(id) }

    func browseAgentFolder(_ path: String?) { activeSession?.browseAgentFolder(path) }
}
