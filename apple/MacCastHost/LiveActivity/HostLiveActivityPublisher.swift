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

    /// The pushes of one ``hostStopping(completion:)`` still on their way.
    private struct Flush {
        var generation: Int?
        var outstanding = 0
        var completions: [@Sendable () -> Void] = []
    }

    private let queue = DispatchQueue(label: "pl.dmq.peering.host.liveactivity")
    private let hostID: String
    private let presence: @Sendable (String) -> PhonePresence
    private let observedChats: @Sendable (String) -> [LiveActivityChatTracker.Observed]
    private let send: Send
    private let flushTimeout: TimeInterval

    private var clients: [String: Client] = [:]
    private var directPathOpen = false
    private var suspendedUntil: ContinuousClock.Instant?
    private var ledger = ActivityPushLedger()
    private var flush = Flush()
    private var flushCount = 0

    init(
        hostID: String,
        flushTimeout: TimeInterval = 1.5,
        presence: @escaping @Sendable (String) -> PhonePresence,
        observedChats: @escaping @Sendable (String) -> [LiveActivityChatTracker.Observed],
        send: @escaping Send
    ) {
        self.hostID = hostID
        self.flushTimeout = flushTimeout
        self.presence = presence
        self.observedChats = observedChats
        self.send = send
    }

    // MARK: - What happened

    func sessionBegan(clientID: String, viaRelay: Bool) {
        queue.async { [self] in
            refresh(clientID) {
                $0.phase = .active
                $0.startedAt = Date()
                $0.viaRelay = viaRelay
            }
        }
    }

    /// `byHost` is a session this Mac ended (unpaired, stopped, reaped); anything else is a connection lost, which the card shows as dropped.
    func sessionEnded(clientID: String, byHost: Bool) {
        queue.async { [self] in
            refresh(clientID) { $0.phase = byHost ? .ended : .dropped }
            if byHost { clients[clientID] = nil }
        }
    }

    func tokens(clientID: String, _ payload: ActivityTokenPayload) {
        queue.async { [self] in
            refresh(clientID) { $0.planner.tokensChanged(payload) }
        }
    }

    /// A phone moved between foreground and background, or one of its chats changed.
    func changed(clientID: String) {
        queue.async { [self] in refresh(clientID) }
    }

    func directPathChanged(_ open: Bool) {
        queue.async { [self] in
            guard open != directPathOpen else { return }
            directPathOpen = open
            for clientID in clients.keys { refresh(clientID) }
        }
    }

    /// Ends every card, then runs `completion` once those pushes have left or the timeout passed, so the caller can close the relay link after them without anyone blocking.
    func hostStopping(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            flush.completions.append(completion)
            guard flush.generation == nil else { return }
            flushCount += 1
            let generation = flushCount
            flush.generation = generation
            for clientID in Array(clients.keys) { refresh(clientID) { $0.phase = .ended } }
            clients.removeAll()
            guard flush.outstanding > 0 else { return finishFlush() }
            queue.asyncAfter(deadline: .now() + flushTimeout) { [self] in
                if flush.generation == generation { finishFlush() }
            }
        }
    }

    /// The relay says why a push was not sent. `requestId` ties it to one push; a relay that does not echo it leaves only the most recent push to blame.
    func refused(_ reason: RelayActivityRefusal, requestId: String?) {
        queue.async { [self] in
            switch reason {
            case .invalidToken:
                guard let pushed = ledger.entry(for: requestId, now: .now) else { return }
                activityLog.notice("the relay refused a Live Activity token; forgetting it")
                refresh(pushed.clientID) { $0.planner.forget(token: pushed.token) }
            case .unavailable:
                activityLog.notice("Live Activity push is unavailable; holding off for a minute")
                suspendedUntil = .now + .seconds(Self.unavailableBackoff)
                for clientID in clients.keys { refresh(clientID) { $0.planner.resend() } }
            case .invalidPayload:
                activityLog.error("the relay refused a Live Activity payload as invalid; not retrying it")
            case .rejected, .other:
                activityLog.notice("the relay did not send a Live Activity push")
            }
        }
    }

    // MARK: - Working it out

    private func refresh(_ clientID: String, _ change: (inout Client) -> Void = { _ in }) {
        let now = Date()
        for command in plan(clientID, now: now, change) {
            deliver(command, clientID: clientID, now: now)
        }
    }

    /// Applies the change, asks the planner what is due and arms the timer for what is not yet.
    private func plan(_ clientID: String, now: Date, _ change: (inout Client) -> Void) -> [LiveActivityCommand] {
        var client = clients[clientID] ?? Client()
        client.timer?.cancel()
        client.timer = nil
        change(&client)

        if let until = suspendedUntil, ContinuousClock.now < until {
            clients[clientID] = client
            schedule(clientID, after: ContinuousClock.now.duration(to: until))
            return []
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
        return commands
    }

    private func schedule(_ clientID: String, at due: Date) {
        schedule(clientID, after: .seconds(max(0, due.timeIntervalSinceNow)))
    }

    private func schedule(_ clientID: String, after delay: Duration) {
        let item = DispatchWorkItem { [weak self] in self?.refresh(clientID) }
        clients[clientID]?.timer = item
        let milliseconds = max(0, delay.components.seconds * 1_000 + delay.components.attoseconds / 1_000_000_000_000_000)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds)), execute: item)
    }

    private func deliver(_ command: LiveActivityCommand, clientID: String, now: Date) {
        do {
            var push = try LiveActivityPushBuilder.push(for: command, hostID: hostID, now: now)
            guard push.contentStateFits else {
                activityLog.error("a Live Activity state was too large to push and was dropped")
                return
            }
            let requestId = ActivityPushLedger.makeRequestID()
            push.requestId = requestId
            ledger.record(requestId: requestId, clientID: clientID, token: command.token, now: .now)
            transmit(push)
        } catch {
            activityLog.error("a Live Activity state could not be encoded: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Counts the push into the flush in progress, if any, so ``hostStopping(completion:)`` waits for exactly the pushes it caused.
    private func transmit(_ push: RelayActivityPush) {
        let generation = flush.generation
        if generation != nil { flush.outstanding += 1 }
        send(push) { [weak self] in
            guard let self else { return }
            queue.async { self.sendCompleted(inFlush: generation) }
        }
    }

    private func sendCompleted(inFlush generation: Int?) {
        guard let generation, flush.generation == generation else { return }
        flush.outstanding -= 1
        if flush.outstanding <= 0 { finishFlush() }
    }

    private func finishFlush() {
        let completions = flush.completions
        flush = Flush()
        for completion in completions { completion() }
    }
}
