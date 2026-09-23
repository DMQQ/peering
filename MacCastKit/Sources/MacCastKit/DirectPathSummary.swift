import Foundation

/// What the finished sessions on this phone say about the direct path.
///
/// `ClientSessionRecord/path` is the connection's path and deliberately not the picture's: a session
/// the relay spliced reads as `Relay` whether or not the picture went around it, so the history
/// alone cannot answer how often the picture avoided the relay.
public struct DirectPathSummary: Sendable {
    /// The sessions that had a relay to avoid: everything in the history that did not stay on
    /// this network.
    ///
    /// The denominator, and the reason it is not every session: a session over the local network
    /// never goes near the relay, so counting it would credit the direct path with a session that
    /// never tested it.
    public let sessionsOffNetwork: Int

    /// Of those, how many sent the picture straight to the Mac.
    public let sessionsDirect: Int

    /// Bytes of picture per second on the direct ones, or `nil` when none of them carried a
    /// picture.
    public let directBytesPerSecond: Double?

    /// The same figure for the sessions whose picture went through the relay.
    public let relayedBytesPerSecond: Double?

    /// How often the picture went around the relay, 0 to 1. A share rather than a percentage,
    /// because the rounding is the screen's decision.
    public var directShare: Double {
        Double(sessionsDirect) / Double(sessionsOffNetwork)
    }

    /// Summarises the records it is handed, and `nil` when there is nothing to summarise.
    ///
    /// The window is the caller's: nothing here filters by date, it counts whatever the history
    /// keeps, so there is no second window to keep in step with the store's.
    ///
    /// `nil` is an empty history and it is also a history in which every session stayed on this
    /// network, because those are the same absence.
    public init?(over records: [ClientSessionRecord]) {
        let offNetwork = records.filter { $0.path != .lan }
        guard !offNetwork.isEmpty else { return nil }

        let direct = offNetwork.filter { Self.pictureWentAroundTheRelay($0) }

        sessionsOffNetwork = offNetwork.count
        sessionsDirect = direct.count
        directBytesPerSecond = Self.pictureBytesPerSecond(of: direct)
        relayedBytesPerSecond = Self.pictureBytesPerSecond(
            of: offNetwork.filter { !Self.pictureWentAroundTheRelay($0) }
        )
    }

    /// Whether this session's picture took a path the relay was not on.
    ///
    /// Two fields because the app arrives at the same fact two ways: `usedDirectPath` is set
    /// whenever the picture went around the relay, and a session whose connection was opened
    /// straight to the Mac reports no datagram path at all, so the flag alone would miss it.
    private static func pictureWentAroundTheRelay(_ record: ClientSessionRecord) -> Bool {
        record.usedDirectPath || record.path == .direct
    }

    /// Bytes of picture per second of session, over the sessions that carried a picture.
    ///
    /// A rate rather than a total, because the two groups are not the same size.
    ///
    /// Sessions with no picture are out of both halves, which is the trap: a session that received
    /// nothing had no picture rather than a cheap one, and counting its minutes would report the
    /// picture as cheaper the more often it failed to arrive. `duration` bottoms out at zero rather
    /// than going negative, so a record with bytes and no seconds is real, and a group with no
    /// picture at all answers `nil` rather than a zero it would be inventing.
    private static func pictureBytesPerSecond(of records: [ClientSessionRecord]) -> Double? {
        let carried = records.filter { $0.videoBytesReceived > 0 && $0.duration > 0 }
        guard !carried.isEmpty else { return nil }

        let bytes = carried.reduce(Int64(0)) { $0 + $1.videoBytesReceived }
        let seconds = carried.reduce(0.0) { $0 + $1.duration }
        return Double(bytes) / seconds
    }
}
