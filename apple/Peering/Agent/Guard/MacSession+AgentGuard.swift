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
        sendAgentAlertPreference()
        for (id, cap) in store.caps() where ids.contains(id) {
            wire?.sendAgent(.setSpendingCap(sessionID: id, cap: cap))
        }
    }

    func sendAgentAlertPreference() {
        let decisionsOnly = UserDefaults.standard.bool(forKey: PreferenceKeys.agentDecisionsOnly)
        wire?.sendAgent(.setAlertPreference(decisionsOnly: decisionsOnly))
    }

    func setAgentSpendingCap(_ cap: AgentSpendingCap?, for id: UUID) {
        do { try agentGuardStore.setCap(cap, for: id) } catch {
            Analytics.failed(error, in: .agent)
        }
        agentSpendingCaps[id] = cap?.isEmpty == false ? cap : nil
        wire?.sendAgent(.setSpendingCap(sessionID: id, cap: cap?.isEmpty == true ? nil : cap))
    }

    /// Sends on the first message a cap held.
    func releaseHeldAgentPrompt(_ id: UUID) {
        wire?.sendAgent(.releaseHeld(sessionID: id))
    }

    func approveAgentPlan(_ approvalID: String, acceptEditsForTurn: Bool, in id: UUID) {
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
