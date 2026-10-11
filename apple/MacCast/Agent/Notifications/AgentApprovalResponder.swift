import MacCastKit
import RemoteCore
import UIKit

/// Answers an approval from its notification's button, with the app possibly launched in the background for nothing else.
@MainActor
enum AgentApprovalResponder {
    /// What iOS leaves a background launch before it suspends the process again, with room to spare.
    private static let modelWait: Duration = .seconds(6)
    private static let connectionWait: Duration = .seconds(18)
    private static let poll: Duration = .milliseconds(200)

    static func answer(_ decision: AgentApprovalDecision, to reference: AgentApprovalNotification.Reference) async {
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Answer agent approval") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }

        let delivered = await send(decision, to: reference)
        let notifier = AgentApprovalNotifier.shared
        if delivered {
            notifier.retract(approvalID: reference.approvalID)
            InAppBanner.shared.resolve(chatID: reference.sessionID)
        } else {
            await notifier.postDeliveryFailure(reference, sessionTitle: IntentHost.model?.agentTitle(reference.sessionID))
        }
    }

    /// The next prompt for a chat, from the button on its "finished" notification.
    static func reply(_ prompt: String, to reference: AgentApprovalNotification.Reference) async {
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Reply to agent chat") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }

        guard let model = await waitForModel(), let hostID = reference.hostID,
              let session = await readySession(of: model, hostID: hostID)
        else {
            await AgentApprovalNotifier.shared.postDeliveryFailure(reference, sessionTitle: IntentHost.model?.agentTitle(reference.sessionID))
            return
        }
        session.sendAgentPrompt(prompt, to: reference.sessionID)
    }

    private static func send(_ decision: AgentApprovalDecision, to reference: AgentApprovalNotification.Reference) async -> Bool {
        guard let model = await waitForModel(), let hostID = reference.hostID else { return false }
        guard let session = await readySession(of: model, hostID: hostID) else { return false }
        session.respondToAgentApproval(reference.approvalID, decision: decision, in: reference.sessionID)
        return true
    }

    private static func waitForModel() async -> SessionModel? {
        await waitFor(modelWait) { IntentHost.model }
    }

    /// Reconnects when the Mac is not up: a dropped connection is the usual state of a phone that was in a pocket.
    private static func readySession(of model: SessionModel, hostID: String) async -> MacSession? {
        func ready() -> MacSession? {
            model.sessions.first { $0.hostID == hostID && $0.phase == .ready && $0.wire != nil }
        }
        if let session = ready() { return session }
        if let known = model.sessions.first(where: { $0.hostID == hostID }) {
            known.resumeWithoutWaiting()
            model.resumeIfNeeded()
        } else {
            model.connectToTrusted(hostID: hostID)
        }
        return await waitFor(connectionWait) { ready() }
    }

    private static func waitFor<Value>(_ limit: Duration, _ value: () -> Value?) async -> Value? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let found = value() { return found }
            try? await Task.sleep(for: poll)
        }
        return value()
    }
}

extension SessionModel {
    func agentTitle(_ sessionID: UUID) -> String? {
        for session in sessions {
            if let chat = session.agentSessions.first(where: { $0.id == sessionID }) { return chat.title }
        }
        return nil
    }
}
