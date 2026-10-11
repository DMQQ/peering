import MacCastKit
import RemoteCore
import UIKit
import UserNotifications

/// `nonisolated` because the system calls the delegate on a queue of its own choosing, and a
/// main-actor conformance traps there. The route is read out as strings and handed to the main actor.
nonisolated final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.notification.request.content.categoryIdentifier == AgentFinishedNotification.category,
           let reference = AgentApprovalNotification.Reference(userInfo: info) {
            let actionID = response.actionIdentifier
            let prompt = AgentFinishedNotification.prompt(
                forActionIdentifier: actionID,
                userText: (response as? UNTextInputNotificationResponse)?.userText
            )
            nonisolated(unsafe) let finish = completionHandler
            Task { @MainActor in
                await Self.handleFinished(reference, actionID: actionID, prompt: prompt)
                finish()
            }
            return
        }
        if let reference = AgentApprovalNotification.Reference(userInfo: info) {
            let actionID = response.actionIdentifier
            // The system's handler may be called from any thread, exactly once.
            nonisolated(unsafe) let finish = completionHandler
            Task { @MainActor in
                await Self.handleApproval(reference, actionID: actionID)
                finish()
            }
            return
        }
        if let hostID = info["hostId"] as? String {
            let source = info["source"] as? String
            Task { @MainActor in NotificationRoute.open(hostID: hostID, sourceID: source) }
        }
        completionHandler()
    }
}

extension NotificationRouter {
    /// A button answers; a tap on the body, or Open, shows the chat. The handler is called only once the answer has left the phone or failed, since iOS may suspend the process the moment it returns.
    @MainActor
    fileprivate static func handleApproval(_ reference: AgentApprovalNotification.Reference, actionID: String) async {
        if let decision = AgentApprovalNotification.decision(forActionIdentifier: actionID, answers: reference.answers) {
            await AgentApprovalResponder.answer(decision, to: reference)
            return
        }
        guard actionID != UNNotificationDismissActionIdentifier else { return }
        InAppBanner.shared.openRequest = .chat(reference.sessionID)
        if let hostID = reference.hostID {
            NotificationRoute.open(hostID: hostID, sourceID: nil)
        }
    }
}

extension NotificationRouter {
    /// A button sends the next prompt; a tap on the body shows the chat.
    @MainActor
    fileprivate static func handleFinished(_ reference: AgentApprovalNotification.Reference, actionID: String, prompt: String?) async {
        if let prompt {
            await AgentApprovalResponder.reply(prompt, to: reference)
            return
        }
        guard actionID != UNNotificationDismissActionIdentifier else { return }
        InAppBanner.shared.openRequest = .chat(reference.sessionID)
        if let hostID = reference.hostID {
            NotificationRoute.open(hostID: hostID, sourceID: nil)
        }
    }
}

@MainActor
enum NotificationRoute {
    private static var pending: (hostID: String, sourceID: String?)?

    static func open(hostID: String, sourceID: String?) {
        guard let model = IntentHost.model else {
            pending = (hostID, sourceID)
            return
        }
        model.openFromNotification(hostID: hostID, sourceID: sourceID)
    }

    static func deliverPending() {
        guard let route = pending, let model = IntentHost.model else { return }
        pending = nil
        model.openFromNotification(hostID: route.hostID, sourceID: route.sourceID)
    }
}
