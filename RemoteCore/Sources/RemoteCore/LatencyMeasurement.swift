import Foundation

/// The pings in flight, and which one a pong answers.
///
/// **The bug this exists to make impossible.** The client kept a single send timestamp and
/// overwrote it with every ping, so a reply could not be told apart from a late reply to the ping
/// before it. A round trip that took a second and a half was measured against a ping sent a moment
/// ago and reported as tens of milliseconds — wrong in the reassuring direction, and most wrong
/// exactly when the link was worst.
///
/// A value type rather than state inside `ClientSession`, so the matching rule can be driven by a
/// test rather than only by a live session: every interesting case here is about *timing*, and
/// timing is the one thing a test cannot wait for.
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
    /// answering rather than merely answered slowly, and a list that kept them all would grow with
    /// the session. They are dropped silently on purpose: an unanswered ping is not a round trip
    /// and must never be reported as one.
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
    /// `sequence` is `nil` for an **empty** pong: a Mac that predates the number and does not echo
    /// it. It still answered *something*, and the honest reading of that is the oldest question
    /// still open rather than the newest, which is exactly the mistake a single timestamp made.
    ///
    /// Every ping older than the one answered went unanswered, and is discarded with it rather
    /// than left in the list to be credited to some later reply. That discard is the point: a lost
    /// ping must not become a very fast one.
    public mutating func answered(sequence: UInt64?) -> Ping? {
        guard !inFlight.isEmpty else { return nil }

        let index: Int
        if let sequence {
            // A pong for a ping that is no longer in flight answers nothing. It cannot be timed,
            // and guessing at it is how the number started lying.
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
/// **A duration, where this used to be five samples.** A count is a window whose length depends on
/// how often the samples arrived: five samples a second apart is five seconds, and five samples
/// after a stall is eight. The figure re-centred on every sample too, which is most of what "it
/// jumps" meant. Ten seconds is long enough that one bad round trip does not own the number and
/// short enough that the number still describes now.
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
    /// A median rather than a mean, deliberately. The interesting samples here are the outliers, a
    /// round trip that caught a stall, and a mean would let one of them drag the figure up while
    /// the connection is fine. A median rather than the newest, for the same reason in reverse: a
    /// single round trip is one instant on a link that is also carrying video the other way, and
    /// what a user wants is the latency they would see if they asked repeatedly.
    public var reported: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.map(\.milliseconds).sorted()
        let middle = sorted.count / 2
        // An even count is averaged rather than rounded up to the higher of the two middle values.
        // A count of five always has a middle, which is why this never came up while the window
        // was a number of samples; a window measured in seconds holds however many arrived, and
        // half of those counts are even. Rounding up would bias the figure high by half a sample
        // whenever it did.
        guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// How long a session has been silent, and whether that is long enough to end it.
///
/// **The fix for a session that froze and never said anything.** A connection can stop carrying
/// without ever reporting a failure: the phone changes network, the path under a socket goes away,
/// and `NWConnection` neither fails nor completes — writes are accepted and nothing comes back.
/// Every layer above waits for an error that never arrives, so the picture stays on its last
/// decoded frame indefinitely and the user is told nothing.
///
/// Silence is the only evidence available, and the client already collects it: one ping a second,
/// and a pong that proves the channel is alive. This is the rule that turns the absence of that
/// pong into a decision, kept apart from the session so it can be tested — every case that matters
/// is about elapsed time, and a test cannot wait for it.
public struct ControlSilence: Sendable {
    /// Ten seconds, which is ten unanswered pings in a row.
    ///
    /// Deliberately twice `VideoFallbackPolicy.controlHealthWindow`, which calls the channel
    /// unhealthy after five. That window is used to *refuse* to move the picture, which is cheap
    /// and reversible; this one ends the session, which is not. A network handover is a few
    /// seconds of silence that often resolves itself, and dropping those would be a worse bug
    /// than the freeze this exists to fix.
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
    /// been one yet — a session whose first pong is late is judged against its own start rather
    /// than against a silence that began before it existed.
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
