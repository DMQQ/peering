import Foundation
import PeeringKit
import RemoteCore
import UIKit
import UserNotifications

/// Working while away: the alert preference and caps the Mac is told, sending on what a cap held, a plan approved at once, and the five-hour warning.
extension MacSession {
    /// After every listing: the Mac keeps neither the caps nor, for a phone it has not met, the preference.
    var agentGuardStore: AgentGuardStore { AgentGuardStore(hostKey: hostID) }

    func sendAwayControls(for ids: Set<UUID>) {
        let store = agentGuardStore
        do { try store.keepCaps(only: ids) } catch {
            Analytics.failed(error, in: .agent)
        }
        agentSpendingCaps = store.caps()
        guard hostSupportsAgentAwayControls else { return }
        sendAgentAlertPreference()
        for (id, cap) in store.caps() where ids.contains(id) {
            wire?.sendAgent(.setSpendingCap(sessionID: id, cap: cap))
        }
    }

    func sendAgentAlertPreference() {
        guard hostSupportsAgentAwayControls else { return }
        let decisionsOnly = UserDefaults.standard.bool(forKey: PreferenceKeys.agentDecisionsOnly)
        wire?.sendAgent(.setAlertPreference(decisionsOnly: decisionsOnly))
    }

    func setAgentSpendingCap(_ cap: AgentSpendingCap?, for id: UUID) {
        do { try agentGuardStore.setCap(cap, for: id) } catch {
            Analytics.failed(error, in: .agent)
        }
        agentSpendingCaps[id] = cap?.isEmpty == false ? cap : nil
        guard hostSupportsAgentAwayControls else { return }
        wire?.sendAgent(.setSpendingCap(sessionID: id, cap: cap?.isEmpty == true ? nil : cap))
    }

    /// Sends on the first message a cap held, wherever the queue is kept.
    func releaseHeldAgentPrompt(_ id: UUID) {
        if hostSupportsAgentQueue {
            guard hostSupportsAgentAwayControls else { return }
            wire?.sendAgent(.releaseHeld(sessionID: id))
            return
        }
        guard var queue = agentQueues[id], let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        guard case .send(let text) = queue.release(state: agentSessions[index].transcript.state) else { return }
        agentQueues[id] = queue.prompts.isEmpty ? nil : queue
        agentSessions[index].transcript.markPromptSent()
        wire?.sendAgent(.prompt(sessionID: id, text: text))
    }

    /// A Mac that queues prompts itself but cannot be told caps holds nothing the phone could send on.
    var agentSpendingCapsAvailable: Bool { hostSupportsAgentAwayControls || !hostSupportsAgentQueue }

    /// A Mac without the request gets a plain allow, which approves the plan and leaves the mode as it was.
    func approveAgentPlan(_ approvalID: String, acceptEditsForTurn: Bool, in id: UUID) {
        guard hostSupportsAgentAwayControls else {
            respondToAgentApproval(approvalID, decision: .allow, in: id)
            return
        }
        wire?.sendAgent(.approvePlan(sessionID: id, approvalID: approvalID, acceptEditsForTurn: acceptEditsForTurn))
    }

    /// The chat shows it from the usage itself; this is the one notification per threshold and window, for a phone not in front.
    func warnIfNearFiveHourLimit(_ usage: AgentUsage, in session: RemoteAgentSession) {
        let store = AgentGuardStore()
        var given = store.givenWarnings
        guard let warning = AgentLimitWarning.due(in: usage.limits, given: &given) else { return }
        store.givenWarnings = given
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = AgentGuardText.limitTitle(warning)
        content.body = AgentGuardText.limitBody(warning)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "peering-agent-limit-\(warning.key)", content: content, trigger: nil)
        Task {
            guard await SessionNotifier.shared.refreshAuthorization() else { return }
            do { try await UNUserNotificationCenter.current().add(request) } catch {
                Analytics.failed(error, in: .notification)
            }
        }
    }
}
