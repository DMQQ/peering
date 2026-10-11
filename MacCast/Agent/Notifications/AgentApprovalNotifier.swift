import Foundation
import MacCastKit
import UserNotifications
import os

private let approvalLog = Logger(subsystem: "pl.dmq.peering", category: "notifications")

/// Puts an agent's approval request on the Lock Screen with the buttons to answer it, and takes it back once it is answered anywhere.
@MainActor
final class AgentApprovalNotifier {
    static let shared = AgentApprovalNotifier()

    private init() {}

    /// A question's buttons carry its own answers, so each question has a category of its own.
    private var optionCategories: [String: UNNotificationCategory] = [:]

    // MARK: - Categories

    /// At launch, before any action can arrive: the system looks a button's category up in what the app registered, and a question's categories are rebuilt from the notifications still delivered.
    func registerCategories() {
        Task {
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            for notification in delivered {
                let info = notification.request.content.userInfo
                guard let reference = AgentApprovalNotification.Reference(userInfo: info),
                      case .options = reference.layoutForCategory
                else { continue }
                let layout = reference.layoutForCategory
                let identifier = AgentApprovalNotification.categoryIdentifier(forLayout: layout, approvalID: reference.approvalID)
                optionCategories[identifier] = Self.category(identifier, layout: layout)
            }
            publishCategories()
        }
    }

    private func publishCategories() {
        let fixed = [
            Self.category(AgentApprovalNotification.toolCategory, layout: .allowDeny),
            Self.category(AgentApprovalNotification.openCategory, layout: .openOnly),
        ]
        UNUserNotificationCenter.current().setNotificationCategories(Set(fixed + [Self.finishedCategory] + optionCategories.values))
    }

    /// Buttons need the phone unlocked: they start work on the Mac.
    private static var finishedCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: AgentFinishedNotification.category,
            actions: [
                UNNotificationAction(
                    identifier: AgentFinishedNotification.continueIdentifier,
                    title: String(localized: "Continue"),
                    options: [.authenticationRequired]
                ),
                UNTextInputNotificationAction(
                    identifier: AgentFinishedNotification.replyIdentifier,
                    title: String(localized: "Reply"),
                    options: [.authenticationRequired],
                    textInputButtonTitle: String(localized: "Send"),
                    textInputPlaceholder: String(localized: "Message")
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    private static func category(_ identifier: String, layout: AgentApprovalNotification.Layout) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: identifier,
            actions: AgentApprovalNotification.actions(for: layout).map(action),
            intentIdentifiers: [],
            options: []
        )
    }

    private static func action(_ action: AgentApprovalNotification.Action) -> UNNotificationAction {
        var options: UNNotificationActionOptions = []
        if action.requiresAuthentication { options.insert(.authenticationRequired) }
        if action.opensApp { options.insert(.foreground) }
        let title: String
        switch action.title {
        case .allow: title = String(localized: "Allow")
        case .deny: title = String(localized: "Deny")
        case .open: title = String(localized: "Open")
        case .option(let label): title = label
        }
        return UNNotificationAction(identifier: action.identifier, title: title, options: options)
    }

    // MARK: - Posting

    func post(_ approval: AgentApprovalNotification, sessionTitle: String, hostID: String?, hostName: String?) async {
        guard await SessionNotifier.shared.refreshAuthorization() else { return }
        if case .options = approval.layout {
            optionCategories[approval.categoryIdentifier] = Self.category(approval.categoryIdentifier, layout: approval.layout)
            publishCategories()
        }
        let content = UNMutableNotificationContent()
        content.title = sessionTitle
        content.subtitle = hostName ?? ""
        content.body = approval.body.isEmpty ? String(localized: "Needs your approval.") : approval.body
        content.sound = .default
        content.categoryIdentifier = approval.categoryIdentifier
        content.threadIdentifier = approval.sessionID.uuidString
        content.userInfo = approval.userInfo(hostID: hostID, answers: approval.answers)
        content.interruptionLevel = .timeSensitive
        await add(content, identifier: approval.identifier)
    }

    /// The answer could not reach the Mac, so the request stays open and the person is told, rather than left believing it was answered.
    func postDeliveryFailure(_ reference: AgentApprovalNotification.Reference, sessionTitle: String?) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your answer did not arrive")
        content.body = sessionTitle.map { String(localized: "Open Peering to answer \($0).") }
            ?? String(localized: "Open Peering to answer.")
        content.sound = .default
        content.categoryIdentifier = AgentApprovalNotification.openCategory
        content.userInfo = AgentApprovalNotification.Reference.userInfo(for: reference)
        content.interruptionLevel = .timeSensitive
        await add(content, identifier: AgentApprovalNotification.identifierPrefix + "failed-" + reference.approvalID)
    }

    private func add(_ content: UNMutableNotificationContent, identifier: String) async {
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        } catch {
            Analytics.failed(error, in: .notification)
            approvalLog.error("could not post \(identifier, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Taking back

    /// Whatever in this chat is no longer pending has been answered: here, on the Mac or on another phone.
    func retain(pending: Set<String>, in sessionID: UUID) {
        retract { reference in reference.sessionID == sessionID && !pending.contains(reference.approvalID) }
    }

    /// The app in front shows its own card and sheet, so a banner left behind only repeats a question already on screen.
    func retractAll() {
        retract { _ in true }
    }

    func retract(approvalID: String) {
        retract { $0.approvalID == approvalID }
    }

    private func retract(where matches: @escaping @Sendable (AgentApprovalNotification.Reference) -> Bool) {
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications()
            var identifiers: [String] = []
            for notification in delivered {
                let request = notification.request
                guard AgentApprovalNotification.isApprovalIdentifier(request.identifier),
                      let reference = AgentApprovalNotification.Reference(userInfo: request.content.userInfo),
                      matches(reference)
                else { continue }
                identifiers.append(request.identifier)
                optionCategories[AgentApprovalNotification.categoryIdentifier(forLayout: reference.layoutForCategory, approvalID: reference.approvalID)] = nil
            }
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            publishCategories()
        }
    }
}
