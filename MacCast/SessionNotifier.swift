import Foundation
import MacCastKit
import RemoteCore
import UIKit
import UserNotifications
import os

private let notifierLog = Logger(subsystem: "pl.dmq.peering", category: "notifications")

/// Puts ``SessionAwareness``'s banners up and takes them back. A singleton because notification permission belongs to the app.
@MainActor
final class SessionNotifier {
    static let shared = SessionNotifier()
    static let remoteTokenChangedName = Notification.Name("pl.dmq.peering.remoteTokenChanged")

    private var hasAskedForPermission = false
    private(set) var remoteToken: Data?
    /// Kept rather than dropped: a phone that never registered looks exactly like a Mac that never sent anything, and this is the only evidence. Shown in Settings.
    private(set) var remoteTokenFailure: String?

    /// Pushed in, like ``SessionPiP/isOnPlan``: this object owns no store.
    /// False until told otherwise, the direction to fail in: a shell stopping raises its banner with no tap, so the wrong default delivers the paid half to someone who has not bought it. Gates the terminal banner only.
    var isOnPlan = false

    private init() {}

    // MARK: - Permission

    /// Asked when the user first reaches for a Mac, not at launch: an app that asks on first run gets denied by reflex.
    func prepareForFirstConnect() {
        guard !hasAskedForPermission else { return }
        hasAskedForPermission = true

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            // Answered questions are not asked again, but the answer is still read: notifications turned on in Settings should apply this time.
            guard settings.authorizationStatus == .notDetermined else {
                let authorized = settings.authorizationStatus == .authorized
                if authorized {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                return
            }
            do {
                let authorized = try await center.requestAuthorization(options: [.alert, .sound])
                if authorized {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                notifierLog.error("could not ask for notification permission: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Read from the system wherever wanted and never cached: the user toggles it in iOS Settings without this process seeing it.
    func refreshAuthorization() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    func remoteTokenDidChange(_ token: Data) {
        remoteToken = token
        remoteTokenFailure = nil
        NotificationCenter.default.post(name: Self.remoteTokenChangedName, object: nil)
    }

    func remoteTokenDidFail(_ error: Error) {
        remoteToken = nil
        remoteTokenFailure = error.localizedDescription
        notifierLog.error("could not register for push: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Banners

    /// Withdraws before posting, so nothing in Notification Center claims a state the session has left.
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

    /// Called when the app returns to the front: a banner behind the screen describes a moment that has passed.
    func retractAll() {
        retract(SessionAwareness.Kind.allCases)
    }

    /// The in-app attention badge updates on every plan; the banner needs the plan, the app not frontmost, and permission.
    /// The Mac also sends this message over the relay and APNs to the registered token, which is what stays reliable while PiP keeps the channel connected but iOS suspends the process; this local route is the fallback with no token.
    /// `macName` is the second line: two Macs can both have a shell called `prod`, and this is read on a locked screen.
    func terminalNeedsAttention(_ message: String, sessionID: UUID, macName: String? = nil) {
        guard isOnPlan, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Terminal needs you")
        content.body = macName.map { "\($0): \(message)" } ?? message
        content.sound = .default
        deliver(content, identifier: "peering-terminal-\(sessionID.uuidString)")
    }

    /// `terminalNeedsAttention` says nothing while the app is in front and the Mac's detector will not fire again for the same prompt, so leaving the screen is the last chance to say so.
    /// The sentence is the Mac's own, so two banners about one state do not read as two features.
    func terminalStillWaiting(
        _ kind: TerminalAttentionKind,
        name: String,
        sessionID: UUID,
        macName: String?
    ) {
        let noun = kind == .password ? String(localized: "a password") : "confirmation"
        terminalNeedsAttention(
            String(localized: "Terminal \u{201C}\(name)\u{201D} is waiting for \(noun)."),
            sessionID: sessionID,
            macName: macName
        )
    }

    /// A command that took a while has returned to the prompt. No `terminalStillWaiting` counterpart: nothing waits on an answer.
    /// Gated on `isOnPlan`; the local route is the fallback when no APNs token exists.
    func terminalFinishedWork(_ message: String, sessionID: UUID, macName: String? = nil) {
        guard isOnPlan, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Terminal finished")
        content.body = macName.map { "\($0): \(message)" } ?? message
        content.sound = .default
        deliver(content, identifier: "peering-terminal-finished-\(sessionID.uuidString)")
    }

    private func post(_ notification: SessionAwareness.Notification) {
        // A banner about the screen the user is looking at is noise, and iOS would not present it anyway.
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        // Sound for the two that can arrive with the phone in a pocket; "Connected" confirms something the user just did.
        content.sound = notification.kind == .connected ? nil : .default

        deliver(content, identifier: notification.identifier)
    }

    /// Permission is read here, not by callers, so it is current: a user who turns notifications on in Settings must be reached by the next shell without a relaunch.
    /// Nothing is scheduled: each is about something that just happened.
    private func deliver(_ content: UNMutableNotificationContent, identifier: String) {
        Task {
            guard await refreshAuthorization() else { return }
            do {
                try await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                )
            } catch {
                notifierLog.error("could not post \(identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Both lists: a request added but not yet delivered sits in pending and would arrive at the wrong moment.
    /// By prefix: an identifier is `kind.hostID`, and a session coming up retires the pairing-code banner of any Mac, including one this end can no longer name.
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
