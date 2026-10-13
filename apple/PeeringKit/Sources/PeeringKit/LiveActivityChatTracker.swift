import Foundation
import RemoteCore

/// Works out which agent chats belong on a Live Activity: the ones doing something, and the ones that just stopped.
///
/// A chat that has been idle since before the Mac was asked is not news, so a chat is listed as finished or failed only after this has watched it stop, and only for ``LiveActivityPushPlanner/finishedLinger``.
public struct LiveActivityChatTracker: Sendable {
    public struct Observed: Sendable, Equatable {
        public var id: String
        public var state: AgentSessionState

        public init(id: String, state: AgentSessionState) {
            self.id = id
            self.state = state
        }
    }

    /// A turn that ends is not yet a finished chat: a CLI that runs helpers in the background starts its next turn within moments, and a card that said "finished" in between was a claim about work that was still going.
    public static let finishHold: TimeInterval = 10

    private var previous: [String: AgentSessionState] = [:]
    private var stopping: [String: ContinuousClock.Instant] = [:]
    private var settled: [String: (state: LiveActivityChat.State, at: ContinuousClock.Instant)] = [:]

    public init() {}

    /// When a chat that has just stopped may be called finished, so the host can look again then.
    public var nextDue: ContinuousClock.Instant? {
        stopping.values.map { $0.advanced(by: .seconds(Self.finishHold)) }.min()
    }

    public mutating func observe(_ sessions: [Observed], symbol: String, now: ContinuousClock.Instant) -> [LiveActivityChat] {
        var busy: [LiveActivityChat] = []
        for session in sessions {
            let before = previous[session.id]
            previous[session.id] = session.state
            switch session.state {
            case .awaitingApproval:
                settled[session.id] = nil
                busy.append(LiveActivityChat(id: session.id, symbol: symbol, state: .needsYou))
            case .working:
                settled[session.id] = nil
                stopping[session.id] = nil
                busy.append(LiveActivityChat(id: session.id, symbol: symbol, state: .working))
            case .idle where before == .working || before == .awaitingApproval || stopping[session.id] != nil:
                let since = stopping[session.id] ?? now
                if now - since >= .seconds(Self.finishHold) {
                    stopping[session.id] = nil
                    settled[session.id] = (.finished, since)
                } else {
                    stopping[session.id] = since
                    busy.append(LiveActivityChat(id: session.id, symbol: symbol, state: .working))
                }
            case .failed where before != nil && before != .failed:
                settled[session.id] = (.failed, now)
            case .idle, .failed, .exited:
                if session.state == .exited { settled[session.id] = nil }
            }
        }
        let present = Set(sessions.map(\.id))
        previous = previous.filter { present.contains($0.key) }
        stopping = stopping.filter { present.contains($0.key) }
        settled = settled.filter { present.contains($0.key) && now - $0.value.at < .seconds(LiveActivityPushPlanner.finishedLinger) }

        let stopped = settled
            .sorted { $0.value.at > $1.value.at }
            .map { LiveActivityChat(id: $0.key, symbol: symbol, state: $0.value.state) }
        return busy + stopped
    }
}
