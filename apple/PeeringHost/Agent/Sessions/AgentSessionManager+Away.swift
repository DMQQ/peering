import Foundation
import PeeringKit
import RemoteCore

/// The requests for working while the person is away: their alert preference, a chat's spending cap, sending on what the cap held, and approving a plan with edits allowed for the rest of the turn.
extension AgentSessionManager {
    func handleAway(_ request: AgentRequest, clientID: String, sink: @escaping Sink) {
        switch request {
        case .setAlertPreference(let decisionsOnly):
            AgentAlertPreferences.shared.set(decisionsOnly: decisionsOnly, for: clientID)
        case .setSpendingCap(let id, let cap):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            lock.withLock { session.spendingCap = cap?.isEmpty == true ? nil : cap }
            persist(session)
        case .releaseHeld(let id):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            releaseHeld(session, sink: sink)
        case .approvePlan(let id, let approvalID, let acceptEditsForTurn):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            approvePlan(session, approvalID: approvalID, acceptEditsForTurn: acceptEditsForTurn)
        default:
            break
        }
    }

    private func releaseHeld(_ session: AgentSession, sink: @escaping Sink) {
        let next: String? = lock.withLock {
            guard case .send(let text) = session.queue.release(state: session.state) else { return nil }
            session.state = .working
            return text
        }
        guard let next else { return }
        announceQueue(of: session)
        if !sendNow(next, to: session) {
            sink(.failed(sessionID: session.id, message: "That chat cannot be continued. Start a new one."))
        }
    }

    private func approvePlan(_ session: AgentSession, approvalID: String, acceptEditsForTurn: Bool) {
        let adapter = adapter(of: session)
        let modes = adapter.permissionModes
        let (approved, lendsEdits): (Bool, Bool) = lock.withLock {
            guard session.pendingApprovals.remove(approvalID) != nil else { return (false, false) }
            defer { session.modeBeforePlan = nil }
            // With the mode before plan unknown there is nothing safe to put back, so edits are not lent.
            guard acceptEditsForTurn, modes.contains(.acceptEdits), let before = session.modeBeforePlan,
                  before != .acceptEdits, before != .auto
            else { return (true, false) }
            session.modeAfterTurn = before
            return (true, true)
        }
        guard approved else { return }
        append(.approvalResolved(approvalID: approvalID, decision: .allow), to: session)
        adapter.respond(approvalID: approvalID, decision: .allow)
        // After the allow on the adapter's own queue, so it lands after the mode the adapter restores on leaving plan mode.
        if lendsEdits { adapter.setPermissionMode(.acceptEdits) }
    }

    /// Called with the lock held, when a turn ends: the mode a plan approval lent for the turn goes back.
    func takeModeAfterTurn(_ session: AgentSession) -> AgentPermissionMode? {
        defer { session.modeAfterTurn = nil }
        return session.modeAfterTurn
    }
}
