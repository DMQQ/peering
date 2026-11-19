import CryptoKit
import Crypto
import Foundation
import Network
import Security

/// Video arrives out of order by design, so the rule is not "greater than the last one": what is
/// rejected is a counter already seen, and one so far behind the newest that it cannot be told from
/// a replay. Ascending counters would throw away exactly the packets that were merely reordered.
public struct VideoReplayWindow: Sendable {
    /// Wide enough for a whole keyframe still being paced out: a sound is sealed after the picture's datagrams but sent between them, so every picture datagram behind it arrives that far behind the newest counter. At 64 the rest of a keyframe was refused as too old and the picture froze while sound and keys still worked.
    public static let size = 8192

    private static let wordCount = size / 64
    private var highest: UInt64 = 0
    private var seen = [UInt64](repeating: 0, count: wordCount)
    private var started = false

    public init() {}

    /// Checked before the datagram is authenticated, and non-mutating: a forged datagram with a huge
    /// counter would otherwise drag the window forward and reject every genuine packet behind it.
    public func accepts(_ counter: UInt64) -> Bool {
        guard started else { return true }
        guard counter <= highest else { return true }
        guard highest - counter < UInt64(Self.size) else { return false }
        return !isMarked(counter)
    }

    public mutating func commit(_ counter: UInt64) {
        guard started else {
            started = true
            highest = counter
            mark(counter)
            return
        }

        if counter > highest {
            let shift = counter - highest
            // A jump wider than the window leaves nothing in it worth remembering.
            if shift >= UInt64(Self.size) {
                seen = [UInt64](repeating: 0, count: Self.wordCount)
            } else {
                var skipped = highest + 1
                while skipped < counter {
                    unmark(skipped)
                    skipped += 1
                }
                unmark(counter)
            }
            highest = counter
        }
        mark(counter)
    }

    public mutating func reset() {
        highest = 0
        seen = [UInt64](repeating: 0, count: Self.wordCount)
        started = false
    }

    private static func slot(_ counter: UInt64) -> (word: Int, bit: UInt64) {
        let index = Int(counter % UInt64(size))
        return (index / 64, UInt64(1) << UInt64(index % 64))
    }

    private func isMarked(_ counter: UInt64) -> Bool {
        let slot = Self.slot(counter)
        return seen[slot.word] & slot.bit != 0
    }

    private mutating func mark(_ counter: UInt64) {
        let slot = Self.slot(counter)
        seen[slot.word] |= slot.bit
    }

    private mutating func unmark(_ counter: UInt64) {
        let slot = Self.slot(counter)
        seen[slot.word] &= ~slot.bit
    }
}
