import Foundation

/// The pings in flight, and which one a pong answers.
///
/// A single send timestamp, overwritten by every ping, cannot tell a reply from a late reply to the
/// ping before it, and reports a slow round trip as a fast one exactly when the link is worst.
///
/// A value type rather than state inside `ClientSession`, so the matching rule can be driven by a
/// test: every interesting case here is about timing, and timing is what a test cannot wait for.
public struct PingLedger: Equatable, Sendable {
    public struct Ping: Equatable, Sendable {
        public let sequence: UInt64
        /// When it went out, in whatever monotonic nanoseconds the caller keeps time in.
        public let sentAtNanoseconds: UInt64
    }

    /// Oldest first. A ping leaves when it is answered, or when it is overtaken.
    public private(set) var inFlight: [Ping] = []
    private var nextSequence: UInt64 = 0

    /// How many unanswered pings are held before the oldest is given up on.
    ///
    /// Four, which is four seconds at the one-second cadence. Past that the link has stopped
    /// answering rather than answered slowly, and a list that kept them all would grow with the
    /// session. An unanswered ping is not a round trip and must never be reported as one.
    public static let inFlightLimit = 4

    public init() {}

    /// Registers a ping that has just been sent, and returns it so its number can travel with it.
    public mutating func record(now: UInt64) -> Ping {
        nextSequence += 1
        let ping = Ping(sequence: nextSequence, sentAtNanoseconds: now)
        inFlight.append(ping)
        if inFlight.count > Self.inFlightLimit {
            inFlight.removeFirst()
        }
        return ping
    }

    /// The ping a pong answers, or `nil` for one that answers nothing.
    ///
    /// `sequence` is `nil` for an empty pong: a Mac that predates the number and does not echo it.
    /// It still answered something, and the honest reading of that is the oldest question still
    /// open rather than the newest.
    ///
    /// Every ping older than the one answered went unanswered and is discarded with it, so a lost
    /// ping never becomes a very fast one.
    public mutating func answered(sequence: UInt64?) -> Ping? {
        guard !inFlight.isEmpty else { return nil }

        let index: Int
        if let sequence {
            // A pong for a ping no longer in flight answers nothing and cannot be timed.
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

/// The round trips inside a stated window, and the figure drawn from them.
///
/// A duration, not a count of samples, whose length would depend on how often the samples arrived:
/// five samples a second apart is five seconds, and five samples after a stall is eight. Ten
/// seconds is long enough that one bad round trip does not own the figure, and short enough that
/// the figure still describes now.
public struct LatencyWindow: Sendable {
    public struct Sample: Equatable, Sendable {
        public let at: TimeInterval
        public let milliseconds: Double
    }

    /// How long a sample stays in the reported figure.
    public let length: TimeInterval
    public private(set) var samples: [Sample] = []

    public init(length: TimeInterval = 10) {
        self.length = length
    }

    public mutating func add(_ milliseconds: Double, at now: TimeInterval) {
        samples.append(Sample(at: now, milliseconds: milliseconds))
        samples.removeAll { now - $0.at > length }
    }

    /// The middle of what arrived in the window, or `nil` when nothing has.
    ///
    /// A median rather than a mean, because the interesting samples are the outliers and a mean
    /// would let one of them drag the figure up while the connection is fine. A median rather than
    /// the newest, because a single round trip is one instant on a link also carrying video: what a
    /// user wants is the latency they would see if they asked repeatedly.
    public var reported: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.milliseconds).sorted()
        let middle = sorted.count / 2
        // An even count is averaged rather than rounded up to the higher of the two middle values,
        // which would bias the figure high by half a sample. A window measured in seconds holds
        // however many arrived, and half of those counts are even.
        guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// How long a session has been silent, and whether that is long enough to end it.
///
/// A connection can stop carrying without reporting a failure: the phone changes network, the path
/// under a socket goes away, and `NWConnection` neither fails nor completes, so writes are accepted
/// and nothing comes back. Every layer above waits for an error that never arrives and the picture
/// stays on its last decoded frame.
///
/// Silence is the only evidence available, and the client already collects it on the ping and pong.
/// Kept apart from the session so it can be tested: every case that matters is about elapsed time.
public struct ControlSilence: Sendable {
    /// Ten seconds, which is ten unanswered pings in a row.
    ///
    /// Deliberately twice `VideoFallbackPolicy.controlHealthWindow`, which calls the channel
    /// unhealthy after five: that window refuses to move the picture, which is cheap and
    /// reversible, while this one ends the session. A network handover is a few seconds of silence
    /// that often resolves itself.
    public static let defaultLimit: TimeInterval = 10

    public let limit: TimeInterval

    public init(limit: TimeInterval = ControlSilence.defaultLimit) {
        self.limit = limit
    }

    /// Whether the control channel has gone too long without answering.
    ///
    /// `isReady` rather than "was ever ready": a session that has already ended must not be judged
    /// again, or a failure becomes a second failure about the same moment.
    ///
    /// The baseline is the last reply, or the moment the session became ready when there has not
    /// been one yet, so a session whose first pong is late is judged against its own start.
    public func hasExpired(
        isReady: Bool,
        readyAt: TimeInterval?,
        lastReplyAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard isReady, let since = lastReplyAt ?? readyAt else { return false }
        return now - since > limit
    }
}
