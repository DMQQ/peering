import PeeringKit
import UserNotifications

/// Gives a pushed question its own answers as buttons. The fixed categories cannot name them, so the Mac sends the
/// answers with the push and this registers a category for that one question before the banner is shown.
final class NotificationService: UNNotificationServiceExtension {
    private let delivery = Delivery()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let original = request.content
        let content = (original.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        delivery.begin(original, handler: contentHandler)

        guard let reference = AgentApprovalNotification.Reference(userInfo: original.userInfo), !reference.answers.isEmpty else {
            delivery.finish(original)
            return
        }
        let layout = reference.layoutForCategory
        let identifier = AgentApprovalNotification.categoryIdentifier(forLayout: layout, approvalID: reference.approvalID)
        content.categoryIdentifier = identifier

        // Handed to one task and not touched again here.
        nonisolated(unsafe) let deliverable = content
        Task { [delivery] in
            let category = UNNotificationCategory(
                identifier: identifier,
                actions: AgentApprovalNotification.actions(for: layout).map(Self.action),
                intentIdentifiers: [],
                options: []
            )
            let center = UNUserNotificationCenter.current()
            var categories = await center.notificationCategories()
            categories.update(with: category)
            center.setNotificationCategories(categories)
            delivery.finish(deliverable)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery.finishWithOriginal()
    }

    private nonisolated static func action(_ action: AgentApprovalNotification.Action) -> UNNotificationAction {
        guard case .option(let label) = action.title else {
            return UNNotificationAction(identifier: action.identifier, title: action.identifier, options: [])
        }
        return UNNotificationAction(identifier: action.identifier, title: label, options: [])
    }
}

/// Hands the content over exactly once, whichever of the work and the system's deadline comes first.
/// `@unchecked Sendable`: every property is guarded by `lock`.
private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    func begin(_ original: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock {
            self.original = original
            self.handler = handler
        }
    }

    func finish(_ content: UNNotificationContent) {
        let handler = lock.withLock { () -> ((UNNotificationContent) -> Void)? in
            defer { self.handler = nil }
            return self.handler
        }
        handler?(content)
    }

    func finishWithOriginal() {
        let original = lock.withLock { self.original }
        if let original { finish(original) }
    }
}
