import Foundation

/// How long the client waits before dialling the video socket again, and when it stops.
///
/// **What this exists for.** On a direct session the video connection is a socket of its own and
/// it is the only thing that can carry a picture: the control-channel fallback is switched off for
/// a LAN path (`SessionModel` sets `videoFallbackEnabled` from the connection path), and the host
/// declines a transport move when no video client is attached, so a socket that closes and is not
/// replaced is a phone watching a frozen frame for the rest of the session. Nothing re-dialled it.
/// `openVideoIfNeeded()` had one caller, `becomeReady()`, which runs once, so the first drop was
/// also the last frame.
///
/// **Bounded rather than endless.** A Mac that will not accept a video connection is a Mac whose
/// answer will not change by being asked again, and a client that asks forever spends a TLS
/// handshake every few seconds on it and fills the host's log with the attempts. Five tries over
/// about fourteen seconds is long enough for a socket the network dropped to come back, and short
/// enough that the screen stops claiming to be trying while the user is still watching it.
///
/// **A rung is spent by a failure, never by a wait.** Only a socket that closed asks for the next
/// one, so a connection that opens and stays open leaves the rest of the ladder untouched however
/// long the session runs.
///
/// The type is here, in values, for the same reason ``VideoFallbackPolicy`` is: every interesting
/// case in it is about timing, and timing is the thing a test must not have to wait for.
public struct VideoReconnectLadder: Sendable {
    /// The wait before each attempt, in order.
    ///
    /// **The first is deliberately short.** A socket that closed because the network moved under it
    /// usually succeeds on the next try, and the difference between half a second and two is the
    /// difference between the picture stuttering and the picture being gone.
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
    /// connects and then says nothing is the failure this ladder is here for, and treating it as a
    /// recovery would leave the session with a spent ladder and no picture.
    public mutating func reset() { attempts = 0 }
}
