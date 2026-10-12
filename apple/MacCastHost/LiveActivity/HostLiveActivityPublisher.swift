import Foundation
import MacCastKit
import RemoteCore
import os

private let activityLog = Logger(subsystem: "pl.dmq.peering.host", category: "liveactivity")

/// Keeps a phone's Live Activities moving while iOS has frozen the app, by asking the relay to push.
///
/// Thin glue: what to push and when is ``LiveActivityPushPlanner``'s, what the card says is ``LiveActivityPushBuilder``'s. Everything runs on one serial queue, so no lock is needed and the planner is never touched from two threads.
final class HostLiveActivityPublisher: @unchecked Sendable {
    typealias Send = @Sendable (RelayActivityPush, @escaping @Sendable () -> Void) -> Void

    /// How long to hold off after the relay says push is unavailable.
    private static let unavailableBackoff: TimeInterval = 60

    private struct Client {
        var planner = LiveActivityPushPlanner()
        var tracker = LiveActivityChatTracker()
        var startedAt: Date?
        var viaRelay = false
        var phase = LiveActivityTruth.Phase.dropped
        var timer: DispatchWorkItem?
    }

    private let queue = DispatchQueue(label: "pl.dmq.peering.host.liveactivity")
    private let hostID: String
    private let presence: @Sendable (String) -> PhonePresence
    private let observedChats: @Sendable (String) -> [LiveActivityChatTracker.Observed]
    private let send: Send

    private var clients: [String: Client] = [:]
    private var directPathOpen = false
    private var suspendedUntil: Date?
    private var lastPushed: (clientID: String, token: String)?

    init(
        hostID: String,
        presence: @escaping @Sendable (String) -> PhonePresence,
        observedChats: @escaping @Sendable (String) -> [LiveActivityChatTracker.Observed],
        send: @escaping Send
    ) {
        self.hostID = hostID
        self.presence = presence
        self.observedChats = observedChats
        self.send = send
    }

    // MARK: - What happened

    func sessionBegan(clientID: String, viaRelay: Bool) {
        queue.async { [self] in
            update(clientID) {
                $0.phase = .active
                $0.startedAt = Date()
                $0.viaRelay = viaRelay
            }
        }
    }

    /// `byHost` is a session this Mac ended (unpaired, stopped, reaped); anything else is a connection lost, which the card shows as dropped.
    func sessionEnded(clientID: String, byHost: Bool) {
        queue.async { [self] in
            update(clientID) { $0.phase = byHost ? .ended : .dropped }
            if byHost { clients[clientID] = nil }
        }
    }

    func tokens(clientID: String, _ payload: ActivityTokenPayload) {
        queue.async { [self] in
            update(clientID) { $0.planner.tokensChanged(payload) }
        }
    }

    func presenceChanged(clientID: String) {
        queue.async { [self] in update(clientID) { _ in } }
    }

    func chatsChanged(clientID: String) {
        queue.async { [self] in update(clientID) { _ in } }
    }

    func directPathChanged(_ open: Bool) {
        queue.async { [self] in
            guard open != directPathOpen else { return }
            directPathOpen = open
            for clientID in clients.keys { update(clientID) { _ in } }
        }
    }

    /// Ends every card before the relay link goes, and waits a moment for the pushes to leave.
    func hostStopping() {
        let group = DispatchGroup()
        queue.sync {
            for clientID in Array(clients.keys) {
                update(clientID, completion: { group.leave() }, onSend: { group.enter() }) { $0.phase = .ended }
            }
            clients.removeAll()
        }
        _ = group.wait(timeout: .now() + 1.5)
    }

    /// The relay says why a push was not sent. It names no token, so the most recent one sent is the one it means.
    func refused(_ reason: RelayActivityRefusal) {
        queue.async { [self] in
            switch reason {
            case .invalidToken:
                guard let last = lastPushed else { return }
                activityLog.notice("the relay refused a Live Activity token; forgetting it")
                update(last.clientID) { $0.planner.forget(token: last.token) }
            case .unavailable:
                activityLog.notice("Live Activity push is unavailable; holding off for a minute")
                suspendedUntil = Date().addingTimeInterval(Self.unavailableBackoff)
                for clientID in clients.keys { update(clientID) { $0.planner.resend() } }
            case .invalidPayload:
                activityLog.error("the relay refused a Live Activity payload as invalid; not retrying it")
            case .rejected, .other:
                activityLog.notice("the relay did not send a Live Activity push")
            }
        }
    }

    // MARK: - Working it out

    private func update(
        _ clientID: String,
        completion: (@Sendable () -> Void)? = nil,
        onSend: (() -> Void)? = nil,
        _ change: (inout Client) -> Void
    ) {
        var client = clients[clientID] ?? Client()
        client.timer?.cancel()
        client.timer = nil
        change(&client)

        let now = Date()
        if let until = suspendedUntil, now < until {
            clients[clientID] = client
            schedule(clientID, at: until)
            return
        }
        let chats = client.tracker.observe(observedChats(clientID), symbol: "sparkles", now: now)
        let truth = LiveActivityTruth(
            phase: client.phase,
            startedAt: client.startedAt,
            path: client.viaRelay ? .relay : (directPathOpen ? .direct : .lan),
            chats: chats
        )
        let commands = client.planner.observe(truth, presence: presence(clientID), now: now)
        clients[clientID] = client
        if let due = client.planner.nextDue { schedule(clientID, at: due) }

        for command in commands {
            onSend?()
            deliver(command, clientID: clientID, now: now, completion: completion)
        }
    }

    private func schedule(_ clientID: String, at due: Date) {
        let item = DispatchWorkItem { [weak self] in self?.update(clientID) { _ in } }
        clients[clientID]?.timer = item
        queue.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow), execute: item)
    }

    private func deliver(_ command: LiveActivityCommand, clientID: String, now: Date, completion: (@Sendable () -> Void)?) {
        do {
            let push = try LiveActivityPushBuilder.push(for: command, hostID: hostID, now: now)
            guard push.contentStateFits else {
                activityLog.error("a Live Activity state was too large to push and was dropped")
                completion?()
                return
            }
            lastPushed = (clientID, command.token)
            send(push) { completion?() }
        } catch {
            activityLog.error("a Live Activity state could not be encoded: \(error.localizedDescription, privacy: .public)")
            completion?()
        }
    }
}
