import Foundation
import RemoteCore

/// Decides which Live Activity pushes one phone is owed, from the true state and where the phone is.
///
/// Pure: it takes the time as an argument and says when it next needs one (``nextDue``), so the host owns the timer and tests need no sleeping.
public struct LiveActivityPushPlanner: Sendable {
    /// The relay lets a token through at one a second once its burst is spent.
    public static let minimumGap: TimeInterval = 1
    /// How long a card about finished work stays up for a tap before the Mac takes it down.
    public static let finishedLinger: TimeInterval = 30 * 60

    private struct Channel {
        var tokens: ActivityTokenPayload?
        var lastSent: Sent?
        var lastSentAt: Date?
        var startSent = false
        /// When the headline became work that has stopped, for the linger.
        var settledSince: Date?
        /// The state each chat was last announced in, so an alert goes out once per change and not again when the phone comes back.
        var announced: [String: LiveActivityChat.State] = [:]
    }

    /// What was last delivered, to tell a change from a repeat. The top chat is in it: a card about another chat is a change.
    private struct Sent: Equatable {
        var phase: LiveActivityTruth.Phase
        var startedAt: Date?
        var path: LiveActivityPath
        var top: LiveActivityChat?
        var waiting: Int
        var working: Int
    }

    private var channels: [LiveActivityKind: Channel] = [:]
    private var latest: LiveActivityTruth?
    private var presence = PhonePresence.gone
    private var held = false

    public init() {}

    /// The phone sent its tokens. Both nil means the activity ended, and nothing more is pushed for it.
    public mutating func tokensChanged(_ payload: ActivityTokenPayload) {
        guard !payload.isEnded else {
            channels[payload.activity] = nil
            return
        }
        var channel = channels[payload.activity] ?? Channel()
        if payload.pushToken != nil { channel.startSent = false }
        channel.tokens = payload
        channels[payload.activity] = channel
    }

    /// Forgets a token the relay said is dead.
    public mutating func forget(token: String) {
        for kind in channels.keys {
            guard var tokens = channels[kind]?.tokens else { continue }
            if tokens.pushToken == token { tokens.pushToken = nil }
            if tokens.pushToStartToken == token { tokens.pushToStartToken = nil }
            if tokens.isEnded {
                channels[kind] = nil
            } else {
                channels[kind]?.tokens = tokens
                channels[kind]?.lastSent = nil
            }
        }
    }

    /// Records the state and returns what is due now.
    public mutating func observe(_ truth: LiveActivityTruth?, presence: PhonePresence, now: Date) -> [LiveActivityCommand] {
        latest = truth
        self.presence = presence
        return evaluate(now: now)
    }

    /// When an update held back for the rate limit should go, or a card about finished work should come down.
    public var nextDue: Date? {
        let lingering = channels.values.compactMap { $0.settledSince?.addingTimeInterval(Self.finishedLinger) }
        let gap = held ? channels.values.compactMap { $0.lastSentAt?.addingTimeInterval(Self.minimumGap) } : []
        return (lingering + gap).min()
    }

    /// Makes the next evaluation send the current state again, after a refusal that was nobody's fault.
    public mutating func resend() {
        for kind in channels.keys { channels[kind]?.lastSent = nil }
    }

    /// Delivers the latest state for anything that was held back.
    public mutating func due(now: Date) -> [LiveActivityCommand] {
        evaluate(now: now)
    }

    private mutating func evaluate(now: Date) -> [LiveActivityCommand] {
        held = false
        guard presence != .foreground else {
            // The app shows its own state now, so what it shows when it leaves again is not what was last pushed.
            for kind in channels.keys {
                channels[kind]?.lastSent = nil
                channels[kind]?.settledSince = nil
            }
            return []
        }
        guard let truth = latest else { return [] }
        return LiveActivityKind.allCases.compactMap { command(for: $0, truth: truth, now: now) }
    }

    private mutating func command(for kind: LiveActivityKind, truth: LiveActivityTruth, now: Date) -> LiveActivityCommand? {
        guard var channel = channels[kind], let tokens = channel.tokens else { return nil }
        defer { channels[kind] = channel }

        guard let token = tokens.pushToken else {
            return start(kind, truth: truth, tokens: tokens, channel: &channel, now: now)
        }
        // A session that is still up but has no connection has nothing to say; chats go on without one.
        guard kind == .agentChat || truth.phase != .active || presence == .background,
              let event = event(for: kind, truth: truth, channel: channel, now: now)
        else { return nil }
        let sent = Self.sent(from: truth)
        guard event == .end || sent != channel.lastSent else { return nil }
        if event != .end, let sentAt = channel.lastSentAt, now.timeIntervalSince(sentAt) < Self.minimumGap {
            held = true
            return nil
        }
        let alert = event == .end ? nil : Self.alert(for: truth, channel: &channel, kind: kind)
        channel.lastSent = sent
        channel.lastSentAt = now
        Self.settle(&channel, headline: kind == .agentChat ? truth.topChat : nil, now: now)
        if event == .end {
            // The activity is over; a later one can only be started by a push-to-start token.
            channel.tokens?.pushToken = nil
            channel.lastSent = nil
            channel.settledSince = nil
        }
        return make(kind, event, token, tokens.environment, truth, alert: alert)
    }

    /// No activity is running to update, so only something that needs the person justifies starting one.
    private func start(
        _ kind: LiveActivityKind,
        truth: LiveActivityTruth,
        tokens: ActivityTokenPayload,
        channel: inout Channel,
        now: Date
    ) -> LiveActivityCommand? {
        if truth.waitingCount == 0 { channel.startSent = false }
        guard kind == .agentChat, truth.phase != .ended,
              truth.waitingCount > 0, !channel.startSent, let startToken = tokens.pushToStartToken
        else { return nil }
        channel.startSent = true
        channel.lastSentAt = now
        if let top = truth.topChat { channel.announced[top.id] = top.state }
        return make(kind, .start, startToken, tokens.environment, truth, alert: .needsApproval)
    }

    private func event(
        for kind: LiveActivityKind,
        truth: LiveActivityTruth,
        channel: Channel,
        now: Date
    ) -> LiveActivityCommand.Event? {
        switch kind {
        case .session:
            return truth.phase == .ended ? .end : .update
        case .agentChat:
            if truth.phase == .ended { return .end }
            if let since = channel.settledSince, now >= since.addingTimeInterval(Self.finishedLinger), truth.topChat.map(Self.isSettled) == true {
                return .end
            }
            if truth.chats.isEmpty {
                // Ends a card this Mac moved, not one the phone is showing from another Mac's chats.
                return channel.lastSent?.top == nil ? nil : .end
            }
            return .update
        }
    }

    private static func isSettled(_ chat: LiveActivityChat) -> Bool {
        chat.state == .finished || chat.state == .failed
    }

    /// Starts the linger clock when the headline becomes work that has stopped, and stops it when newer work takes the headline.
    private static func settle(_ channel: inout Channel, headline: LiveActivityChat?, now: Date) {
        guard let headline, isSettled(headline) else {
            channel.settledSince = nil
            return
        }
        if channel.settledSince == nil { channel.settledSince = now }
    }

    private static func alert(for truth: LiveActivityTruth, channel: inout Channel, kind: LiveActivityKind) -> LiveActivityCommand.Alert? {
        guard kind == .agentChat, let top = truth.topChat, channel.announced[top.id] != top.state else { return nil }
        channel.announced[top.id] = top.state
        switch top.state {
        case .needsYou: return .needsApproval
        case .finished: return .finished
        case .failed: return .failed
        case .working: return nil
        }
    }

    private func make(
        _ kind: LiveActivityKind,
        _ event: LiveActivityCommand.Event,
        _ token: String,
        _ environment: PushEnvironment,
        _ truth: LiveActivityTruth,
        alert: LiveActivityCommand.Alert?
    ) -> LiveActivityCommand {
        LiveActivityCommand(
            kind: kind,
            event: event,
            token: token,
            environment: environment,
            truth: truth,
            priority: alert == nil ? nil : 10,
            alert: alert
        )
    }

    private static func sent(from truth: LiveActivityTruth) -> Sent {
        Sent(
            phase: truth.phase,
            startedAt: truth.startedAt,
            path: truth.path,
            top: truth.topChat,
            waiting: truth.waitingCount,
            working: truth.workingCount
        )
    }
}
