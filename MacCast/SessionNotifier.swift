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
    static let remoteTokenChangedName = Notification.Name("pl.dmq.peering.remoteTokenChanged")

    private var hasAskedForPermission = false
    /// The current APNs device token, set when the OS delivers one.
    private(set) var remoteToken: Data?

    /// Whether the plan includes the Mac being able to reach this device about a terminal.
    ///
    /// **Pushed in rather than read here**, the way ``SessionPiP/isOnPlan`` is, and for the same
    /// reason: this object owns no store, and a plan read inside it would be a second copy of an
    /// entitlement nothing keeps in step with the first. ``SessionModel`` tells it, from the one
    /// function that owns that answer.
    ///
    /// **False until something says otherwise**, and that is the direction to fail in. The
    /// decision this gates has no tap to wait for: a shell stopping raises its banner by itself,
    /// so the wrong default is the paid half of the feature arriving for somebody who has not
    /// bought it. It gates the terminal's banner only. The banners about a session's own state
    /// are free on every plan and do not ask this.
    var isOnPlan = false

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

    /// Whether banners may be posted, asked of the system rather than remembered.
    ///
    /// **Because the decision is not one this app finishes.** It is asked for once, on the first
    /// connection, and what the user does next is go to iOS Settings, turn it on or off, and come
    /// back — none of which this process sees. So it is read wherever it is wanted, which is where
    /// a banner is about to be posted and where the answer is shown, and nothing caches it: a
    /// remembered copy of this is a user who turned notifications on an hour ago and hears nothing
    /// until the next launch.
    func refreshAuthorization() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    /// Called by the app delegate when the OS delivers or refreshes the APNs device token.
    func remoteTokenDidChange(_ token: Data) {
        remoteToken = token
        NotificationCenter.default.post(name: Self.remoteTokenChangedName, object: nil)
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
    /// in-app attention badge is always updated, on every plan, because it belongs to the
    /// terminal; this adds a banner only when the plan includes being told, while Peering is not
    /// frontmost, and once notification permission has been granted.
    ///
    /// **The same message is sent by the Mac when no session is up**, over the relay and APNs,
    /// to the token the phone registered on the way in. The two are one feature and are gated as
    /// one: see ``PlanCapability/terminalAlerts``, which is also where the registration is
    /// refused, so a plan without it leaves the Mac with no token to send this to at all.
    ///
    /// `macName` is the second line rather than the first, because the message is what the user
    /// needs and the Mac is what tells them which of several to look at: two Macs can both have a
    /// shell called `prod`, and this is read on a locked screen with nothing else on it.
    func terminalNeedsAttention(_ message: String, sessionID: UUID, macName: String? = nil) {
        guard isOnPlan, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Terminal needs you"
        content.body = macName.map { "\($0): \(message)" } ?? message
        content.sound = .default
        deliver(content, identifier: "peering-terminal-\(sessionID.uuidString)")
    }

    /// The banner for a shell the user walked away from with a prompt still open.
    ///
    /// ``terminalNeedsAttention(_:sessionID:macName:)`` says nothing while the app is in front,
    /// which is right, and the Mac's detector will not fire again for the same prompt: it waits
    /// for an answer before it will recognise another. So a prompt that arrived while the user was
    /// looking had no way of ever reaching them once they put the phone down, and leaving the
    /// screen is the second and last chance to say so.
    ///
    /// The sentence is the Mac's own, from ``TerminalSessionManager``, because both of them end up
    /// on the same Lock Screen: one banner reading "Terminal “prod” is waiting for a password" and
    /// another reading something else about the same state would look like two features.
    func terminalStillWaiting(
        _ kind: TerminalAttentionKind,
        name: String,
        sessionID: UUID,
        macName: String?
    ) {
        let noun = kind == .password ? "a password" : "confirmation"
        terminalNeedsAttention(
            "Terminal \u{201C}\(name)\u{201D} is waiting for \(noun).",
            sessionID: sessionID,
            macName: macName
        )
    }

    private func post(_ notification: SessionAwareness.Notification) {
        // A banner about the screen the user is looking at is noise rather than news, and on
        // a frontmost app iOS would not present it anyway — the check here is what keeps the
        // "not posted" decision in one readable place instead of in the delegate's rules.
        guard UIApplication.shared.applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        // Sound for the two that can arrive with the phone in a pocket. "Connected" is
        // confirmation of something the user just did, to someone already holding the phone.
        content.sound = notification.kind == .connected ? nil : .default

        deliver(content, identifier: notification.identifier)
    }

    /// The one place a banner is handed to iOS, and the one place the permission is read.
    ///
    /// Read here rather than checked by the callers, so that the answer is the one the system has
    /// *now*: the user is told about a shell waiting while notifications are off, turns them on in
    /// iOS Settings, and the next shell to stop has to reach them without a relaunch in between.
    ///
    /// Nothing is scheduled: every one of these is about something that has just happened, so a
    /// trigger would only be a delay.
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
