import Foundation
import RemoteCore

/// The events the Mac keeps for one session, so a phone that comes back can ask for what it missed.
public struct AgentTranscriptBuffer: Sendable {
    public private(set) var events: [AgentStreamEvent]
    public private(set) var nextIndex: UInt64
    public private(set) var truncatedAtFront: Bool
    private var bytes: Int

    public var lastIndex: UInt64 { nextIndex - 1 }

    public init() {
        events = []
        nextIndex = 1
        truncatedAtFront = false
        bytes = 0
    }

    public init(restoring events: [AgentStreamEvent], nextIndex: UInt64, truncatedAtFront: Bool) {
        self.events = events
        self.nextIndex = max(nextIndex, (events.last?.index ?? 0) + 1)
        self.truncatedAtFront = truncatedAtFront
        bytes = events.reduce(0) { $0 + Self.approximateBytes(of: $1.payload) }
    }

    /// A reply's final text replaces the deltas that built it, so they are dropped here and replay does not send the text twice.
    @discardableResult
    public mutating func append(_ payload: AgentStreamEvent.Payload, limit: Int = AgentLimits.maximumTranscriptBytes) -> AgentStreamEvent {
        if case .textFinal = payload { dropTrailingDeltas() }
        let event = AgentStreamEvent(index: nextIndex, payload: payload)
        events.append(event)
        nextIndex += 1
        bytes += Self.approximateBytes(of: payload)
        trim(limit: limit)
        return event
    }

    /// Everything after `since`, split so no chunk passes the byte or event budget.
    public func chunks(
        since: UInt64,
        byteBudget: Int,
        eventBudget: Int = AgentLimits.maximumReplayEvents
    ) -> [[AgentStreamEvent]] {
        var chunks: [[AgentStreamEvent]] = []
        var current: [AgentStreamEvent] = []
        var size = 0
        for event in events where event.index > since {
            let eventSize = Self.approximateBytes(of: event.payload)
            if !current.isEmpty, current.count >= eventBudget || size + eventSize > byteBudget {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(event)
            size += eventSize
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private mutating func dropTrailingDeltas() {
        while let last = events.last, case .textDelta = last.payload {
            bytes -= Self.approximateBytes(of: last.payload)
            events.removeLast()
        }
    }

    /// Whole turns go first, oldest first. One turn that is itself too big keeps its shape and loses its tool output instead.
    private mutating func trim(limit: Int) {
        while bytes > limit, let cut = secondTurnStart() {
            bytes -= events[0..<cut].reduce(0) { $0 + Self.approximateBytes(of: $1.payload) }
            events.removeFirst(cut)
            truncatedAtFront = true
        }
        guard bytes > limit else { return }
        for position in events.indices {
            guard case .toolFinished(let id, let ok, _?, _) = events[position].payload else { continue }
            let before = Self.approximateBytes(of: events[position].payload)
            let shrunk = AgentStreamEvent.Payload.toolFinished(callID: id, ok: ok, output: nil, truncated: true)
            events[position] = AgentStreamEvent(index: events[position].index, payload: shrunk)
            bytes -= before - Self.approximateBytes(of: shrunk)
            if bytes <= limit { break }
        }
    }

    private func secondTurnStart() -> Int? {
        var seen = 0
        for (position, event) in events.enumerated() {
            guard case .userPrompt = event.payload else { continue }
            seen += 1
            if seen == 2 { return position }
        }
        return nil
    }

    public static func approximateBytes(of payload: AgentStreamEvent.Payload) -> Int {
        switch payload {
        case .userPrompt(let text), .textFinal(let text), .textDelta(let text), .notice(let text):
            return text.utf8.count
        case .failure(let message):
            return message.utf8.count
        case .toolStarted(let call):
            return (call.detail ?? "").utf8.count + (call.diff ?? "").utf8.count
        case .toolFinished(_, _, let output, _):
            return (output ?? "").utf8.count
        case .sessionReady, .turnStarted, .approvalRequested, .approvalResolved, .turnFinished, .sessionExited:
            return 64
        }
    }
}
