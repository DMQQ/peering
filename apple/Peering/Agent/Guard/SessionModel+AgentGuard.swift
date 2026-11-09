import Foundation
import PeeringKit
import RemoteCore

extension SessionModel {
    func agentSpendingCap(for id: UUID) -> AgentSpendingCap? {
        activeSession.flatMap { $0.agentSpendingCaps[id] ?? $0.agentGuardStore.cap(for: id) }
    }

    func setAgentSpendingCap(_ cap: AgentSpendingCap?, for id: UUID) {
        activeSession?.setAgentSpendingCap(cap, for: id)
    }

    func releaseHeldAgentPrompt(_ id: UUID) {
        activeSession?.releaseHeldAgentPrompt(id)
    }

    func approveAgentPlan(_ approvalID: String, acceptEditsForTurn: Bool, in id: UUID) {
        activeSession?.approveAgentPlan(approvalID, acceptEditsForTurn: acceptEditsForTurn, in: id)
    }

    /// Every connected Mac, since each decides its own pushes.
    func agentAlertPreferenceChanged() {
        for session in sessions where session.phase == .ready {
            session.sendAgentAlertPreference()
        }
    }
}
