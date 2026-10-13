import Foundation
import PeeringKit
import os
import RemoteCore

/// Applying one adapter event to its session, and what follows from it: the owner's stream, a push, telemetry, the disk.
extension AgentSessionManager {
    /// What one event did to a session, worked out under the lock and acted on after it.
    struct Applied {
        var event: AgentStreamEvent
        var sink: Sink?
        var push: (title: String, body: String, action: RelayPushAction?)?
        var correctedModel: String?
        var emission: AgentTurnTelemetry.Emission?
        var activityChanged: Bool?
        var stateChanged = false
        var persists = false
    }

    func append(_ payload: AgentStreamEvent.Payload, to session: AgentSession) {
        // Read before the lock: one lock order everywhere avoids deadlock with the token store. Only the two events that can push need it, not every delta.
        let token = Self.mayPush(payload) ? PushTokenStore.shared.tokensByClient()[session.ownerClientID] : nil
        let phone = presence?(session.ownerClientID) ?? .gone
        let applied = lock.withLock { apply(payload, to: session, token: token, presence: phone) }

        if let emission = applied.emission {
            AgentTurnTelemetry.send(emission, agentID: session.agentID, sessionID: session.id)
        }
        if let sink = applied.sink {
            forward(.stream(sessionID: session.id, event: applied.event), from: session, index: applied.event.index, to: sink)
        }
        if let corrected = applied.correctedModel {
            applied.sink?(.modelChanged(sessionID: session.id, model: corrected))
        }
        if let push = applied.push, let token {
            onPushNeeded?(token, push.title, push.body, push.action)
        }
        if let active = applied.activityChanged {
            onActivityChanged?(active)
        }
        if applied.stateChanged { onChatStateChanged?(session.ownerClientID) }
        if applied.persists { persist(session) }
    }

    static func mayPush(_ payload: AgentStreamEvent.Payload) -> Bool {
        switch payload {
        case .approvalRequested, .turnFinished: true
        default: false
        }
    }

    /// Called with the lock held.
    private func apply(
        _ payload: AgentStreamEvent.Payload,
        to session: AgentSession,
        token: String?,
        presence: PhonePresence
    ) -> Applied {
        let stateBefore = session.state
        let event = session.transcript.append(payload)
        var applied = Applied(event: event)
        let name = AgentCatalogue.entry(for: session.agentID)?.name ?? session.agentID

        switch payload {
        case .turnStarted:
            session.state = .working
            session.turnEditedFiles = []
        case .toolStarted(let call):
            if AgentTurnDigest.edits(call), let path = call.filePath { session.turnEditedFiles.insert(path) }
        case .approvalRequested(let approvalID, let call, let reason):
            session.pendingApprovals.insert(approvalID)
            session.state = .awaitingApproval
            // Reaches the user even with the socket open: the phone may be suspended behind Picture in Picture.
            if token != nil {
                let text = AgentNotificationText.approval(agentName: name, reason: reason, detail: call.detail, words: .localized)
                applied.push = (text.title, text.body, RelayPushAction(
                    category: AgentApprovalNotification.pushCategory(for: call),
                    sessionID: session.id.uuidString,
                    approvalID: approvalID
                ))
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
            if PushPolicy.shouldPush(presence: presence, hasToken: token != nil) {
                let text = AgentNotificationText.finished(
                    agentName: name, ok: summary.ok, stopped: summary.stopped, lastReply: session.lastReply,
                    editedFiles: session.turnEditedFiles.count, duration: summary.duration, words: .localized
                )
                applied.push = (text.title, text.body, summary.ok ? RelayPushAction(
                    category: AgentFinishedNotification.category,
                    sessionID: session.id.uuidString,
                    approvalID: ""
                ) : nil)
            }
        case .failure(let message):
            session.state = .failed
            // The CLI has lost this conversation: a prompt must not try to resume it again.
            if message == AgentExpiry.message { session.cliSessionID = nil }
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
        case .textDelta, .notice, .toolFinished, .child:
            break
        }

        applied.emission = session.telemetry.record(payload, model: session.model)
        applied.sink = sinks[session.ownerClientID]
        if session.state != stateBefore {
            applied.stateChanged = true
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
