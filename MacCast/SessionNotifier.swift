import Foundation
import MacCastKit
import RemoteCore
import UIKit
import UserNotifications
import os

private let notifierLog = Logger(subsystem: "pl.dmq.peering", category: "notifications")

/// Puts ``SessionAwareness``'s banners up, and takes them back once the session has moved
/// past what they said.
///
/// A singleton because the thing it talks to is one: notification permission is granted to
/// the app, not to an object, so a second instance would only be a second copy of a fact that
/// is already global.
@MainActor
final class SessionNotifier {
    static let shared = SessionNotifier()

    private var hasAskedForPermission = false
    private var isAuthorized = false

    private init() {}

    // MARK: - Permission

    /// Called when the user first reaches for a Mac — not at launch.
    ///
    /// The prompt is a decision nobody has the context for until they have tried to connect
    /// to something, and an app that asks on first run is an app whose notifications get
    /// denied by reflex. What is being asked for is exactly "tell me when the Mac needs me",
    /// so it is asked at the moment the user demonstrates they want that.
    func prepareForFirstConnect() {
        guard !hasAskedForPermission else { return }
        hasAskedForPermission = true

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            // A question already answered is not asked again, whichever way it was answered.
            // The answer is still read, because someone who turned notifications on in
            // Settings since the last launch should get them this time.
            guard settings.authorizationStatus == .notDetermined else {
                isAuthorized = settings.authorizationStatus == .authorized
                return
            }
            do {
                isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                notifierLog.error("could not ask for notification permission: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Banners

    /// The one entry point the model uses, on every phase change.
    ///
    /// Withdraws before posting: arriving at `.ready` retires the pairing prompt, a fresh
    /// attempt retires the failure before it, so nothing is left in Notification Center
    /// claiming a state the session has already left.
    func sessionMoved(
        from previous: ClientSession.Phase,
        to phase: ClientSession.Phase,
        hostName: String,
        hostID: String? = nil,
        deliberate: Bool,
        resuming: Bool = false
    ) {
        switch phase {
        case .connecting, .handshaking:
            retract([.connectionEnded, .awaitingPairingCode])
        case .confirming:
            retract([.connectionEnded])
        case .ready:
            retract([.awaitingPairingCode, .connectionEnded])
        case .idle, .failed, .disconnected:
            break
        }

        guard let notification = SessionAwareness.notification(
            from: previous,
            to: phase,
            hostName: hostName,
            hostID: hostID,
            deliberate: deliberate,
            resuming: resuming
        ) else { return }

        post(notification)
    }

    /// Everything this feature has ever put in Notification Center, called when the app comes
    /// back to the front: from that moment the screen is what the user is reading, and a
    /// banner behind it describes a moment that has passed.
    func retractAll() {
        retract(SessionAwareness.Kind.allCases)
    }

    /// Terminal prompts are the case where the Mac explicitly needs the person back. The
    /// in-app attention badge is always updated; this adds a banner only while Peering is not
    /// frontmost and notification permission has already been granted.
    /// `macName` is the second line rather than the first, because the message is what the user
    /// needs and the Mac is what tells them which of several to look at: two Macs can both have a
    /// shell called `prod`, and this is read on a locked screen with nothing else on it.
    func terminalNeedsAttention(_ message: String, sessionID: UUID, macName: String? = nil) {
        guard isAuthorized, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Terminal needs you"
        content.body = macName.map { "\($0): \(message)" } ?? message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "peering-terminal-\(sessionID.uuidString)",
            content: content,
            trigger: nil
        )
        Task {
            do { try await UNUserNotificationCenter.current().add(request) }
            catch { notifierLog.error("could not post terminal attention: \(String(describing: error), privacy: .public)") }
        }
    }

    private func post(_ notification: SessionAwareness.Notification) {
        // A banner about the screen the user is looking at is noise rather than news, and on
        // a frontmost app iOS would not present it anyway — the check here is what keeps the
        // "not posted" decision in one readable place instead of in the delegate's rules.
        guard isAuthorized, UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        // Sound for the two that can arrive with the phone in a pocket. "Connected" is
        // confirmation of something the user just did, to someone already holding the phone.
        content.sound = notification.kind == .connected ? nil : .default

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            // Nothing is scheduled here. Every one of these is about something that has just
            // happened, so a trigger would only be a delay.
            trigger: nil
        )

        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                notifierLog.error("could not post \(notification.kind.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Takes banners back by the identifier their kind owns. Both lists, because a request
    /// that has been added but not yet delivered sits in the pending one — and it would then
    /// arrive at exactly the wrong moment.
    ///
    /// **By prefix rather than by exact name**, which is what several Macs made necessary: an
    /// identifier is now `kind.hostID`, so the exact string is no longer knowable from the kind
    /// alone, and the Mac whose state has changed is not always the one being asked about — a
    /// session coming up retires the pairing-code banner of any Mac, including one this end can
    /// no longer name because its session has already been let go of.
    ///
    /// Reading what is delivered is an `await`, which is why this is a `Task` where it used to be
    /// three synchronous lines. Nothing waits on it: taking a banner back is housekeeping, and a
    /// user who sees it for a moment longer has lost nothing.
    private func retract(_ kinds: [SessionAwareness.Kind]) {
        guard !kinds.isEmpty else { return }
        let prefixes = kinds.map(\.identifier)
        let center = UNUserNotificationCenter.current()
        Task {
            let delivered = await center.deliveredNotifications()
            let pending = await center.pendingNotificationRequests()
            let owned = (delivered.map(\.request.identifier) + pending.map(\.identifier))
                .filter { identifier in prefixes.contains { identifier.hasPrefix($0) } }
            guard !owned.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: owned)
            center.removePendingNotificationRequests(withIdentifiers: owned)
        }
    }
}
