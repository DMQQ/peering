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
    private var lastSentAt: ContinuousClock.Instant?
    private var sentAtOffset: [UInt64: ContinuousClock.Instant] = [:]
    /// Timeouts in a row with no progress, which is how a driver notices a lossy path that stopped working.
    public private(set) var consecutiveTimeouts = 0

    public init() {}

    public var bufferedBytes: Int { buffer.count }
    public var hasUnacknowledged: Bool { nextOffset > acked }

    public mutating func enqueue(_ bytes: Data) {
        buffer.append(bytes)
    }

    public mutating func acknowledge(upTo offset: UInt64, now: ContinuousClock.Instant) {
        let sent = acked + UInt64(buffer.count)
        guard offset > acked, offset <= sent else { return }
        if let at = sentAtOffset.filter({ $0.key < offset }).max(by: { $0.key < $1.key })?.value {
            noteRoundTrip(now - at)
        }
        sentAtOffset = sentAtOffset.filter { $0.key >= offset }
        buffer = Data(buffer.dropFirst(Int(offset - acked)))
        acked = offset
        nextOffset = max(nextOffset, offset)
        consecutiveTimeouts = 0
        lastSentAt = hasUnacknowledged ? now : nil
    }

    /// The path the bytes travel changed: whatever was in flight on the old one may be lost.
    public mutating func carrierChanged() {
        nextOffset = acked
        sentAtOffset = [:]
        lastSentAt = nil
        consecutiveTimeouts = 0
    }

    /// What to put on the carrier now. On a lossy one, bytes unacknowledged for longer than the timeout are sent again from the first missing one.
    public mutating func frames(now: ContinuousClock.Instant, carrier: Carrier) -> [ControlPipeFrame] {
        if carrier == .lossy, let last = lastSentAt, hasUnacknowledged, now - last >= timeout {
            nextOffset = acked
            sentAtOffset = [:]
            consecutiveTimeouts += 1
            timeout = min(Self.maximumTimeout, timeout * 2)
        }
        var out: [ControlPipeFrame] = []
        let end = acked + UInt64(buffer.count)
        let limit = carrier == .lossy ? acked + UInt64(Self.lossyWindowBytes) : end
        while nextOffset < min(end, limit) {
            let start = Int(nextOffset - acked)
            let piece = carrier == .lossy ? Self.maxPayload : Self.maxReliablePayload
            let count = min(piece, buffer.count - start, Int(limit - nextOffset))
            out.append(.data(offset: nextOffset, payload: buffer.subdata(in: start..<start + count)))
            sentAtOffset[nextOffset + UInt64(count)] = now
            nextOffset += UInt64(count)
        }
        if !out.isEmpty { lastSentAt = now }
        return out
    }

    /// When a lossy carrier should next be given a chance to resend, or nil with nothing outstanding.
    public func retransmitDeadline() -> ContinuousClock.Instant? {
        guard hasUnacknowledged, let last = lastSentAt else { return nil }
        return last + timeout
    }

    private mutating func noteRoundTrip(_ sample: Duration) {
        let smoothed = smoothedRoundTrip.map { ($0 * 7 + sample) / 8 } ?? sample
        smoothedRoundTrip = smoothed
        timeout = min(Self.maximumTimeout, max(Self.minimumTimeout, smoothed * 3))
    }
}
