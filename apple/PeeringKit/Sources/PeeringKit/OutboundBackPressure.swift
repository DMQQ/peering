import Foundation

/// Bytes handed to a connection that it has not yet reported sent. A phone that stopped reading leaves this growing, and the figure is what says to stop producing.
public struct OutboundBackPressure: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case backedUp
        case drained
    }

    public static let highWaterBytes = 4 * 1024 * 1024
    /// Lower than the high mark so a queue hovering at the limit does not flip the gate on every send.
    public static let lowWaterBytes = 1024 * 1024

    public private(set) var inFlightBytes = 0
    public private(set) var isBackedUp = false

    public init() {}

    public mutating func queued(_ bytes: Int) -> Change? {
        inFlightBytes += max(0, bytes)
        guard !isBackedUp, inFlightBytes >= Self.highWaterBytes else { return nil }
        isBackedUp = true
        return .backedUp
    }

    public mutating func completed(_ bytes: Int) -> Change? {
        inFlightBytes = max(0, inFlightBytes - max(0, bytes))
        guard isBackedUp, inFlightBytes <= Self.lowWaterBytes else { return nil }
        isBackedUp = false
        return .drained
    }
}
