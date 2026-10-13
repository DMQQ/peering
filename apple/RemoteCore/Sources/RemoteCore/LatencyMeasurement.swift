import Foundation

/// A single send timestamp cannot tell a reply from a late reply to the previous ping, and reports a slow round trip as fast.
public struct PingLedger: Equatable, Sendable {
    public struct Ping: Equatable, Sendable {
        public let sequence: UInt64
        public let sentAtNanoseconds: UInt64
    }

    public private(set) var inFlight: [Ping] = []
    private var nextSequence: UInt64 = 0

    /// Four, which is four seconds at the one-second cadence: past that the link has stopped answering. An unanswered ping must never be reported as a round trip.
    public static let inFlightLimit = 4

    public init() {}

    public mutating func record(now: UInt64) -> Ping {
        nextSequence += 1
        let ping = Ping(sequence: nextSequence, sentAtNanoseconds: now)
        inFlight.append(ping)
        if inFlight.count > Self.inFlightLimit {
            inFlight.removeFirst()
        }
        return ping
    }

    /// `sequence` is `nil` for an empty pong from a Mac that does not echo it: read as the oldest open ping.
    /// Older pings are discarded, so a lost ping never becomes a very fast one.
    public mutating func answered(sequence: UInt64?) -> Ping? {
        guard !inFlight.isEmpty else { return nil }

        let index: Int
        if let sequence {
            guard let found = inFlight.firstIndex(where: { $0.sequence == sequence }) else {
                return nil
            }
            index = found
        } else {
            index = 0
        }

        let ping = inFlight[index]
        inFlight.removeFirst(index + 1)
        return ping
    }
}

/// A duration, not a sample count: ten seconds so one bad round trip does not own the figure, yet it still describes now.
public struct LatencyWindow: Sendable {
    public struct Sample: Equatable, Sendable {
        public let at: TimeInterval
        public let milliseconds: Double
    }

    public let length: TimeInterval
    public private(set) var samples: [Sample] = []

    public init(length: TimeInterval = 10) {
        self.length = length
    }

    public mutating func add(_ milliseconds: Double, at now: TimeInterval) {
        samples.append(Sample(at: now, milliseconds: milliseconds))
        samples.removeAll { now - $0.at > length }
    }

    /// A median: a mean lets one outlier drag the figure up, and the newest is a single instant on a link also carrying video.
    public var reported: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.milliseconds).sorted()
        let middle = sorted.count / 2
        // Averaged for an even count rather than rounded up, which would bias the figure high.
        guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// A connection can stop carrying without failing (network handover): `NWConnection` neither fails nor completes, so the picture freezes on its last frame. Silence on the ping and pong is the only evidence.
public struct ControlSilence: Sendable {
    /// Twice `VideoFallbackPolicy.controlHealthWindow`: that window only refuses to move the picture (cheap, reversible), while this one ends the session, and a handover is often a few seconds of silence.
    public static let defaultLimit: TimeInterval = 10

    /// The check runs twice a second, so a longer gap since the last one means the process itself was not running.
    public static let freezeGap: TimeInterval = 3

    public enum Verdict: Equatable, Sendable {
        case healthy
        /// The silence is real time but the app was frozen for it: no ping went out and no pong was read, so it says nothing about the network.
        case resumedFromFreeze
        case expired
    }

    public let limit: TimeInterval

    public init(limit: TimeInterval = ControlSilence.defaultLimit) {
        self.limit = limit
    }

    /// `isReady` rather than "was ever ready", so a session that already ended is not judged again.
    /// Baseline is the last reply, or the moment the session became ready, or the moment a freeze ended if that is later.
    public func judge(
        isReady: Bool,
        readyAt: TimeInterval?,
        lastReplyAt: TimeInterval?,
        restartedAt: TimeInterval?,
        previousCheckAt: TimeInterval?,
        now: TimeInterval
    ) -> Verdict {
        guard isReady, let since = [lastReplyAt ?? readyAt, restartedAt].compactMap({ $0 }).max() else { return .healthy }
        guard now - since > limit else { return .healthy }
        if let previousCheckAt, now - previousCheckAt > Self.freezeGap { return .resumedFromFreeze }
        return .expired
    }
}
