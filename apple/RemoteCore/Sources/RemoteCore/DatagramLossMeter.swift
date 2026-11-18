import Foundation

/// How much of what the Mac sent in the last interval never arrived, read from the gaps in the datagram counters.
/// A lost datagram usually costs nothing visible while parity can rebuild it, which is why this is the earlier signal: it moves before a picture is dropped.
public struct DatagramLossMeter: Sendable, Equatable {
    private var highest: UInt64?
    private var highestAtLastSample: UInt64?
    private var receivedSinceLastSample = 0

    public init() {}

    /// Called once per datagram that authenticated, in any order.
    public mutating func note(counter: UInt64) {
        if let current = highest {
            receivedSinceLastSample += 1
            if counter > current { highest = counter }
        } else {
            // The first datagram is the baseline the later ones are counted against, not a datagram of any interval.
            highest = counter
            highestAtLastSample = counter
        }
    }

    /// The fraction lost since the previous sample, or `nil` when nothing new arrived and so nothing can be said.
    /// A datagram that arrives late counts for the interval it arrives in, so a reordered one can only make the figure smaller.
    public mutating func sample() -> Double? {
        defer { receivedSinceLastSample = 0 }
        guard let highest, let base = highestAtLastSample, highest > base else { return nil }
        let expected = Int(clamping: highest - base)
        highestAtLastSample = highest
        let lost = max(0, expected - receivedSinceLastSample)
        return Double(lost) / Double(expected)
    }

    public mutating func reset() {
        self = DatagramLossMeter()
    }
}
