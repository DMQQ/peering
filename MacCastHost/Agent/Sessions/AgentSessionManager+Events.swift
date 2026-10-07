import Foundation
import MacCastKit
import os
import RemoteCore

/// Applying one adapter event to its session, and what follows from it: the owner's stream, a push, telemetry, the disk.
extension AgentSessionManager {
    /// What one event did to a session, worked out under the lock and acted on after it.
    struct Applied {
        var event: AgentStreamEvent
        var sink: Sink?
        var push: (title: String, body: String)?
        var correctedModel: String?
        var emission: AgentTurnTelemetry.Emission?
        var activityChanged: Bool?
        var persists = false
    }

    func append(_ payload: AgentStreamEvent.Payload, to session: AgentSession) {
        // Read before the lock: one lock order everywhere avoids deadlock with the token store. Only the two events that can push need it, not every delta.
        let token = Self.mayPush(payload) ? PushTokenStore.shared.tokensByClient()[session.ownerClientID] : nil
        let applied = lock.withLock { apply(payload, to: session, token: token) }

        if let emission = applied.emission {
            AgentTurnTelemetry.send(emission, agentID: session.agentID, sessionID: session.id)
        }
        applied.sink?(.stream(sessionID: session.id, event: applied.event))
        if let corrected = applied.correctedModel {
            applied.sink?(.modelChanged(sessionID: session.id, model: corrected))
        }
        if let push = applied.push, let token {
            onPushNeeded?(token, push.title, push.body)
        }
        if let active = applied.activityChanged {
            onActivityChanged?(active)
        }
        if applied.persists { persist(session) }
    }

    static func mayPush(_ payload: AgentStreamEvent.Payload) -> Bool {
        switch payload {
        case .approvalRequested, .turnFinished: true
        default: false
        }
    }

    /// Called with the lock held.
    private func apply(_ payload: AgentStreamEvent.Payload, to session: AgentSession, token: String?) -> Applied {
        let stateBefore = session.state
        let event = session.transcript.append(payload)
        var applied = Applied(event: event)
        let name = AgentCatalogue.entry(for: session.agentID)?.name ?? session.agentID

        switch payload {
        case .turnStarted:
            session.state = .working
        case .approvalRequested(let approvalID, let call, let reason):
            session.pendingApprovals.insert(approvalID)
            session.state = .awaitingApproval
            // Reaches the user even with the socket open: the phone may be suspended behind Picture in Picture.
            if token != nil {
                applied.push = AgentNotificationText.approval(agentName: name, reason: reason, detail: call.detail)
            }
        case .approvalResolved(let approvalID, _):
            session.pendingApprovals.remove(approvalID)
            if session.pendingApprovals.isEmpty, session.state == .awaitingApproval {
                session.state = .working
            }
        case .userPrompt:
            applied.persists = true
        case .textFinal(let text):
            session.lastReply = text
        case .turnFinished(let summary):
            session.pendingApprovals.removeAll()
            session.state = .idle
            applied.persists = true
            // The CLI's own answer wins: a Mac whose config pins a model keeps running it whatever the picker was told.
            if let model = summary.model, model != session.model {
                session.model = model
                applied.correctedModel = model
            }
            if sinks[session.ownerClientID] == nil, token != nil {
                applied.push = AgentNotificationText.finished(
                    agentName: name, ok: summary.ok, stopped: summary.stopped, lastReply: session.lastReply
                )
            }
        case .failure:
            session.state = .failed
            applied.persists = true
        case .sessionExited:
            session.state = .exited
            session.adapterLive = false
            applied.persists = true
        case .sessionReady(_, let cliSessionID, let model, _):
            if let cliSessionID { session.cliSessionID = cliSessionID }
            if let model, model != session.model {
                session.model = model
                applied.correctedModel = model
            }
            applied.persists = true
        case .textDelta, .notice, .toolStarted, .toolFinished, .child:
            break
        }

        applied.emission = session.telemetry.record(payload, model: session.model)
        applied.sink = sinks[session.ownerClientID]
        if session.state != stateBefore {
            let nowActive = sessions.values.contains { $0.isBusy }
            if nowActive != wasActive {
                wasActive = nowActive
                applied.activityChanged = nowActive
            }
        }
        return applied
    }

    func persist(_ session: AgentSession) {
        // Taken on the queue, so saves land in the order they ran, and skipped for a chat that was closed while this waited.
        persistQueue.async { [weak self] in
            guard let self, let record = self.lock.withLock({ self.sessions[session.id] == nil ? nil : session.record }) else { return }
            do { try self.store.save(record) } catch {
                Analytics.failed(error, in: .agent)
                agentLog.error("agent chat could not be saved · \(String(describing: error), privacy: .public)")
            }
        }
    }
}
