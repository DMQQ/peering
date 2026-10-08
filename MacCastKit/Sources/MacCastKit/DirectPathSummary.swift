import Foundation

/// What the finished sessions on this phone say about the direct path.
public struct DirectPathSummary: Sendable {
    /// The sessions that had a relay to avoid: everything in the history that did not stay on
    /// this network.
    public let sessionsOffNetwork: Int

    public let sessionsDirect: Int

    /// Bytes of picture per second on the direct ones, or `nil` when none of them carried a
    /// picture.
    public let directBytesPerSecond: Double?

    public let relayedBytesPerSecond: Double?

    /// How often the picture went around the relay, 0 to 1. A share rather than a percentage,
    /// because the rounding is the screen's decision.
    public var directShare: Double {
        Double(sessionsDirect) / Double(sessionsOffNetwork)
    }

    /// Summarises the records it is handed, and `nil` when there is nothing to summarise.
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
    private static func pictureWentAroundTheRelay(_ record: ClientSessionRecord) -> Bool {
        record.usedDirectPath || record.path == .direct
    }

    /// Bytes of picture per second of session, over the sessions that carried a picture.
    private static func pictureBytesPerSecond(of records: [ClientSessionRecord]) -> Double? {
        let carried = records.filter { $0.videoBytesReceived > 0 && $0.duration > 0 }
        guard !carried.isEmpty else { return nil }

        let bytes = carried.reduce(Int64(0)) { $0 + $1.videoBytesReceived }
        let seconds = carried.reduce(0.0) { $0 + $1.duration }
        return Double(bytes) / seconds
    }
}
