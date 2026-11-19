import Foundation

/// The sending half of the control pipe: keeps every byte until the far end has said it arrived, so a different carrier can resend what the old one lost.
public struct ControlPipeSender: Sendable {
    public enum Carrier: Sendable { case reliable, lossy }

    /// One datagram's worth. A reliable carrier takes larger pieces, since a stream does not care.
    public static let maxPayload = 1000
    public static let maxReliablePayload = 16 * 1024
    /// What may be unacknowledged on a lossy carrier. The picture shares that path, so the control stream stays a small fraction of it.
    public static let lossyWindowBytes = 32 * 1000
    static let initialTimeout: Duration = .milliseconds(400)
    static let minimumTimeout: Duration = .milliseconds(200)
    static let maximumTimeout: Duration = .seconds(3)

    private var buffer = Data()
    private var acked: UInt64 = 0
    private var nextOffset: UInt64 = 0
    private var timeout = initialTimeout
    private var smoothedRoundTrip: Duration?
    /// When the oldest unacknowledged byte was last sent: the retransmit timer runs from here and nowhere else. Measured from the latest send instead, any steady traffic (a moving mouse, a ping a second) pushed the deadline out for as long as it lasted, and one lost datagram stalled the whole stream until the user stopped.
    private var retransmitStartedAt: ContinuousClock.Instant?
    /// Acknowledgements that repeated the last one: the receiver is holding later bytes behind a gap, which says the first segment is lost without waiting for the timer.
    private var duplicateAcks = 0
    private var fastRetransmitDue = false
    /// Where the stream had reached when a loss was repaired. An acknowledgement short of it means another gap, repaired at once.
    private var recoveryEnd: UInt64?
    static let duplicateAcksBeforeRetransmit = 3
    private var sentAtOffset: [UInt64: ContinuousClock.Instant] = [:]
    /// Timeouts in a row with no progress, which is how a driver notices a lossy path that stopped working.
    public private(set) var consecutiveTimeouts = 0

    public init() {}

    public var bufferedBytes: Int { buffer.count }
    public var hasUnacknowledged: Bool { nextOffset > acked }
    /// Sent and not yet acknowledged: what this stream is holding of a budget shared with others.
    public var inFlightBytes: Int { Int(nextOffset - acked) }
    /// Where the stream ends once everything queued so far is sent: a completion waits for the far end to acknowledge up to here.
    public var enqueuedEnd: UInt64 { acked + UInt64(buffer.count) }
    public var ackedOffset: UInt64 { acked }

    public mutating func enqueue(_ bytes: Data) {
        buffer.append(bytes)
    }

    public mutating func acknowledge(upTo offset: UInt64, now: ContinuousClock.Instant) {
        let sent = acked + UInt64(buffer.count)
        if offset == acked, hasUnacknowledged {
            duplicateAcks += 1
            if duplicateAcks >= Self.duplicateAcksBeforeRetransmit { fastRetransmitDue = true }
            return
        }
        guard offset > acked, offset <= sent else { return }
        if let at = sentAtOffset.filter({ $0.key < offset }).max(by: { $0.key < $1.key })?.value {
            noteRoundTrip(now - at)
        }
        sentAtOffset = sentAtOffset.filter { $0.key >= offset }
        buffer = Data(buffer.dropFirst(Int(offset - acked)))
        acked = offset
        nextOffset = max(nextOffset, offset)
        consecutiveTimeouts = 0
        duplicateAcks = 0
        timeout = smoothedRoundTrip.map { min(Self.maximumTimeout, max(Self.minimumTimeout, $0 * 3)) } ?? Self.initialTimeout
        retransmitStartedAt = hasUnacknowledged ? now : nil
        if let end = recoveryEnd {
            if offset >= end {
                recoveryEnd = nil
            } else if hasUnacknowledged {
                fastRetransmitDue = true
            }
        }
    }

    /// The path the bytes travel changed: whatever was in flight on the old one may be lost.
    public mutating func carrierChanged() {
        nextOffset = acked
        sentAtOffset = [:]
        retransmitStartedAt = nil
        consecutiveTimeouts = 0
        duplicateAcks = 0
        fastRetransmitDue = false
        recoveryEnd = nil
    }

    /// What to put on the carrier now. On a lossy one, a lost segment is sent again alone, when its timer runs out or when later bytes have been acknowledged past it three times: the stream behind it was already sent and the receiver is holding it, so resending the lot would only add to the loss.
    /// `window` caps what may be in flight on a lossy carrier; the default is this stream's own share, and a caller running several streams passes what is left of theirs together.
    public mutating func frames(now: ContinuousClock.Instant, carrier: Carrier, window: Int = lossyWindowBytes) -> [ControlPipeFrame] {
        var out: [ControlPipeFrame] = []
        if carrier == .lossy, hasUnacknowledged {
            let timedOut = retransmitStartedAt.map { now - $0 >= timeout } ?? false
            if timedOut || fastRetransmitDue {
                let count = min(Self.maxPayload, Int(nextOffset - acked), buffer.count)
                out.append(.data(offset: acked, payload: buffer.prefix(count)))
                // The earlier send of this segment may still be answered, which would time the wrong trip.
                sentAtOffset[acked + UInt64(count)] = nil
                if timedOut {
                    consecutiveTimeouts += 1
                    timeout = min(Self.maximumTimeout, timeout * 2)
                }
                recoveryEnd = max(recoveryEnd ?? 0, nextOffset)
                fastRetransmitDue = false
                duplicateAcks = 0
                retransmitStartedAt = now
            }
        }
        let end = acked + UInt64(buffer.count)
        let limit = carrier == .lossy ? acked + UInt64(max(0, window)) : end
        while nextOffset < min(end, limit) {
            let start = Int(nextOffset - acked)
            let piece = carrier == .lossy ? Self.maxPayload : Self.maxReliablePayload
            let count = min(piece, buffer.count - start, Int(limit - nextOffset))
            out.append(.data(offset: nextOffset, payload: buffer.subdata(in: start..<start + count)))
            sentAtOffset[nextOffset + UInt64(count)] = now
            nextOffset += UInt64(count)
        }
        if retransmitStartedAt == nil, hasUnacknowledged { retransmitStartedAt = now }
        return out
    }

    /// When a lossy carrier should next be given a chance to resend, or nil with nothing outstanding.
    public func retransmitDeadline() -> ContinuousClock.Instant? {
        guard hasUnacknowledged, let started = retransmitStartedAt else { return nil }
        return started + timeout
    }

    private mutating func noteRoundTrip(_ sample: Duration) {
        let smoothed = smoothedRoundTrip.map { ($0 * 7 + sample) / 8 } ?? sample
        smoothedRoundTrip = smoothed
        timeout = min(Self.maximumTimeout, max(Self.minimumTimeout, smoothed * 3))
    }
}
