import Foundation

/// On a direct session the video socket is the only thing that can carry a picture: the
/// control-channel fallback is off for a LAN path (`SessionModel` sets `videoFallbackEnabled` from
/// the connection path), and the host declines a transport move when no video client is attached.
/// A socket that closes and is not replaced is a frozen frame for the rest of the session.
public struct VideoReconnectLadder: Sendable {
    /// The first is deliberately short: a socket that closed because the network moved under it
    /// usually succeeds on the next try.
    public static let delays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(5),
    ]

    public private(set) var attempts = 0

    public init() {}

    public mutating func next() -> Duration? {
        guard attempts < Self.delays.count else { return nil }
        defer { attempts += 1 }
        return Self.delays[attempts]
    }

    public var isSpent: Bool { attempts >= Self.delays.count }

    /// Called when the picture actually arrives rather than when a socket opens: a socket that
    /// connects and then says nothing is the failure this ladder is here for.
    public mutating func reset() { attempts = 0 }
}
