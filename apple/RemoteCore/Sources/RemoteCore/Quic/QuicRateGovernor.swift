import Foundation

/// Sets the picture's bitrate from what QUIC measures, so the stream never asks more of a link than it carries. A queue of picture datagrams waiting in quiche is the sign the bitrate is above the path: then it drops at once to below what was actually delivered. With no queue it climbs back gradually toward the ceiling the user chose.
public struct QuicRateGovernor: Sendable, Equatable {
    public static let floorKbps = 1_000
    /// Waiting datagrams worth more than this much sending time count as a queue.
    static let queueTolerance: Duration = .milliseconds(40)
    /// Fraction of the measured delivery rate the picture is allowed after a queue.
    static let backoffShare = 0.7
    /// Growth per decision while the path keeps up.
    static let climb = 1.08

    public private(set) var targetKbps: Int

    public init(startingKbps: Int) {
        targetKbps = max(Self.floorKbps, startingKbps)
    }

    public struct Reading: Sendable {
        public var ceilingKbps: Int
        public var backlogBytes: Int
        public var deliveryRateBytesPerSecond: UInt64
        public var bandwidthBytesPerSecond: UInt64

        public init(ceilingKbps: Int, backlogBytes: Int, deliveryRateBytesPerSecond: UInt64, bandwidthBytesPerSecond: UInt64) {
            self.ceilingKbps = ceilingKbps
            self.backlogBytes = backlogBytes
            self.deliveryRateBytesPerSecond = deliveryRateBytesPerSecond
            self.bandwidthBytesPerSecond = bandwidthBytesPerSecond
        }
    }

    /// One decision. Returns the new target when it changed enough to be worth telling the encoder.
    public mutating func decide(_ reading: Reading) -> Int? {
        let ceiling = max(Self.floorKbps, reading.ceilingKbps)
        let pathBytesPerSecond = max(reading.bandwidthBytesPerSecond, reading.deliveryRateBytesPerSecond)
        let tolerated = Double(pathBytesPerSecond) * Self.queueTolerance.seconds
        let queued = reading.backlogBytes > max(16_384, Int(tolerated))

        let next: Int
        if queued {
            // Below what was actually delivered, and never above where it already was.
            let delivered = Int(Double(reading.deliveryRateBytesPerSecond) * 8 / 1000 * Self.backoffShare)
            next = min(targetKbps, max(Self.floorKbps, delivered > 0 ? delivered : targetKbps / 2))
        } else {
            next = min(ceiling, Int(Double(targetKbps) * Self.climb) + 100)
        }
        let previous = targetKbps
        targetKbps = min(ceiling, max(Self.floorKbps, next))
        // Small steps are not worth reconfiguring the encoder for.
        return abs(targetKbps - previous) * 20 >= previous ? targetKbps : nil
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
