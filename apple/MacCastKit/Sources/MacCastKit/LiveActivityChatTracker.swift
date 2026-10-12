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

    private var previous: [String: AgentSessionState] = [:]
    private var settled: [String: (state: LiveActivityChat.State, at: Date)] = [:]

    public init() {}

    public mutating func observe(_ sessions: [Observed], symbol: String, now: Date) -> [LiveActivityChat] {
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
                busy.append(LiveActivityChat(id: session.id, symbol: symbol, state: .working))
            case .idle where before == .working || before == .awaitingApproval:
                settled[session.id] = (.finished, now)
            case .failed where before != nil && before != .failed:
                settled[session.id] = (.failed, now)
            case .idle, .failed, .exited:
                if session.state == .exited { settled[session.id] = nil }
            }
        }
        let present = Set(sessions.map(\.id))
        previous = previous.filter { present.contains($0.key) }
        settled = settled.filter { present.contains($0.key) && now.timeIntervalSince($0.value.at) < LiveActivityPushPlanner.finishedLinger }

        let stopped = settled
            .sorted { $0.value.at > $1.value.at }
            .map { LiveActivityChat(id: $0.key, symbol: symbol, state: $0.value.state) }
        return busy + stopped
    }
}
