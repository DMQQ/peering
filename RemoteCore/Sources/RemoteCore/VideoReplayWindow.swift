import CryptoKit
import Crypto
import Foundation
import Network
import Security

/// Video arrives out of order by design, so the rule is not "greater than the last one": what is
/// rejected is a counter already seen, and one so far behind the newest that it cannot be told from
/// a replay. Ascending counters would throw away exactly the packets that were merely reordered.
public struct VideoReplayWindow: Sendable {
    public static let size = 64

    private var highest: UInt64 = 0
    private var seen: UInt64 = 0
    private var started = false

    public init() {}

    /// Checked before the datagram is authenticated, and non-mutating: a forged datagram with a huge
    /// counter would otherwise drag the window forward and reject every genuine packet behind it.
    public func accepts(_ counter: UInt64) -> Bool {
        guard started else { return true }
        guard counter <= highest else { return true }
        let distance = highest - counter
        guard distance < UInt64(Self.size) else { return false }
        return seen & (1 << UInt64(distance)) == 0
    }

    public mutating func commit(_ counter: UInt64) {
        guard started else {
            started = true
            highest = counter
            seen = 1
            return
        }

        if counter > highest {
            let shift = counter - highest
            // A jump wider than the window leaves nothing in it worth remembering, so the
            // bitmap starts again rather than pretending to know about counters it never saw.
            seen = shift >= UInt64(Self.size) ? 0 : seen << shift
            seen |= 1
            highest = counter
        } else {
            seen |= 1 << (highest - counter)
        }
    }

    public mutating func reset() {
        highest = 0
        seen = 0
        started = false
    }
}
