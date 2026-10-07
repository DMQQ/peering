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
        if let hostID = info["hostId"] as? String {
            let source = info["source"] as? String
            Task { @MainActor in NotificationRoute.open(hostID: hostID, sourceID: source) }
        }
        completionHandler()
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
