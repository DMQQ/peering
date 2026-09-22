import Foundation

/// What the finished sessions on this phone say about the direct path.
///
/// **Why it exists.** "Did punching work, and how often" has been an opinion since the feature
/// shipped, and a second relay region is meant to be decided on the number rather than on the
/// opinion. Every finished session already records both halves of the answer — which way its
/// picture went and what that cost in bytes — and nothing has ever added them up. This is that
/// sum, and it is a pure function of the records it is handed so that it can be checked with no
/// device, no session and no relay.
///
/// **It is not a restatement of the list beside it.** The Sessions tab draws each finished session
/// under its ``ClientSessionRecord/Path``, which is the *connection's* path and deliberately not
/// the picture's: a session the relay spliced reads as `Relay` whether or not the picture went
/// around it. Thirty rows of that cannot answer how often the picture avoided the relay, which is
/// the question this type exists to answer.
public struct DirectPathSummary: Sendable {
    /// The sessions that had a relay to avoid: everything in the history that did not stay on
    /// this network.
    ///
    /// **The denominator, and the reason it is not every session.** A session over the local
    /// network never goes near the relay, so counting it as a picture that avoided one would
    /// flatter the feature with sessions that were never a test of it. The question here is what
    /// happens to a session that has to leave, which is the one that decides whether another
    /// region is worth building.
    public let sessionsOffNetwork: Int

    /// Of those, how many sent the picture straight to the Mac.
    public let sessionsDirect: Int

    /// Bytes of picture per second on the direct ones, or `nil` when none of them carried a
    /// picture.
    public let directBytesPerSecond: Double?

    /// The same figure for the sessions whose picture went through the relay.
    public let relayedBytesPerSecond: Double?

    /// How often the picture went around the relay, 0 to 1.
    ///
    /// A share rather than a label, because how it is rounded is the screen's decision and this
    /// is the arithmetic: the count it came from is at most a few dozen, and a figure presented
    /// here as a percentage would be one the reader has to un-round to check.
    public var directShare: Double {
        Double(sessionsDirect) / Double(sessionsOffNetwork)
    }

    /// Summarises the records it is handed, and `nil` when there is nothing to summarise.
    ///
    /// **The window is the caller's, and that is deliberate.** Nothing here filters by date or
    /// assumes how far back the records go: whatever the history keeps is what gets counted, which
    /// on this phone is the store's thirty most recent sessions. A window chosen here would be a
    /// second one to keep in step with the store's, and the two would disagree the first time
    /// either moved.
    ///
    /// `nil` is an empty history and it is also a history in which every session stayed on this
    /// network, because those are the same absence: no session has yet had to leave. A card
    /// reporting "0 of 0" would be presenting that absence as a result.
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
    /// **Two fields, because the app can arrive at the same fact two ways.** `usedDirectPath` is
    /// what the session reported about its picture, and it is the answer whenever it is set: a
    /// session can be spliced by the relay and still send the picture around it, which is the
    /// whole point of punching and the case the Sessions list cannot show. A session whose
    /// *connection* was opened straight to the Mac, by a typed-in address rather than through the
    /// relay, never had a relayed picture either — and those sessions report no datagram path at
    /// all, because there was no relay lane to report on, so the flag alone would miss them.
    private static func pictureWentAroundTheRelay(_ record: ClientSessionRecord) -> Bool {
        record.usedDirectPath || record.path == .direct
    }

    /// Bytes of picture per second of session, over the sessions that carried a picture.
    ///
    /// **A rate rather than a total, because the two groups are not the same size.** Twelve direct
    /// sessions and three relayed ones have totals that differ mostly by how many there were, and
    /// what the comparison is for is what the picture cost while it was arriving.
    ///
    /// **Sessions with no picture are out of both halves, and that is the trap.** A session that
    /// received nothing did not have a cheap picture, it had none: counting its minutes in the
    /// denominator would report the picture as cheaper the more often it failed to arrive. A
    /// session with no duration is out for the same reason from the other end, having bytes and no
    /// seconds to spread them over — `duration` bottoms out at zero rather than going negative, so
    /// those records are real. `nil` when nothing in the group carried a picture, which the card
    /// can decline to draw rather than print a zero it would be inventing.
    private static func pictureBytesPerSecond(of records: [ClientSessionRecord]) -> Double? {
        let carried = records.filter { $0.videoBytesReceived > 0 && $0.duration > 0 }
        guard !carried.isEmpty else { return nil }

        let bytes = carried.reduce(Int64(0)) { $0 + $1.videoBytesReceived }
        let seconds = carried.reduce(0.0) { $0 + $1.duration }
        return Double(bytes) / seconds
    }
}
