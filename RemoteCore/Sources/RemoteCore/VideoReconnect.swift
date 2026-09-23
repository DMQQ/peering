import Foundation

/// How long the client waits before dialling the video socket again, and when it stops.
///
/// On a direct session the video socket is the only thing that can carry a picture: the
/// control-channel fallback is off for a LAN path (`SessionModel` sets `videoFallbackEnabled` from
/// the connection path), and the host declines a transport move when no video client is attached.
/// A socket that closes and is not replaced is a frozen frame for the rest of the session.
///
/// Bounded, because a Mac that will not accept a video connection will not change its answer. A rung
/// is spent by a failure, never by a wait, so a connection that opens and stays open leaves the rest
/// of the ladder untouched. The type is here rather than in the app for the same reason
/// ``VideoFallbackPolicy`` is: the interesting cases are about timing, which a test must not wait for.
public struct VideoReconnectLadder: Sendable {
    /// The wait before each attempt, in order.
    ///
    /// The first is deliberately short: a socket that closed because the network moved under it
    /// usually succeeds on the next try.
    public static let delays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(5),
    ]

    /// How many attempts have been handed out, which is also how many have failed.
    public private(set) var attempts = 0

    public init() {}

    /// How long to wait before the next attempt, or `nil` when there is none left to make.
    public mutating func next() -> Duration? {
        guard attempts < Self.delays.count else { return nil }
        defer { attempts += 1 }
        return Self.delays[attempts]
    }

    /// Whether the next ask would come back empty.
    public var isSpent: Bool { attempts >= Self.delays.count }

    /// Starts again at the first rung.
    ///
    /// Called when the picture actually arrives rather than when a socket opens: a socket that
    /// connects and then says nothing is the failure this ladder is here for.
    public mutating func reset() { attempts = 0 }
}
