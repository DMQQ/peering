import Foundation

public enum VideoTransport: String, Codable, Sendable, Equatable, CaseIterable {
    case primary
    /// Video here shares the link that carries input and the catalogue, which is worth the price
    /// only when the alternative is no picture at all, which is why the rate is capped. See
    case control
}

/// The client decides, because the host cannot see whether its datagrams arrive: nothing
/// acknowledges them, and a send into a network that drops it looks like a send that worked.
public struct VideoTransportRequest: Codable, Sendable, Equatable {
    public let transport: VideoTransport
    public let reason: String

    public init(transport: VideoTransport, reason: String) {
        self.transport = transport
        self.reason = reason
    }
}

/// Not a measure of the link: nothing here times packets, measures throughput or counts losses. The
/// question is only "is a picture arriving", the only one answerable from the client's side.
public struct VideoFallbackPolicy: Sendable {
    public enum Decision: Sendable, Equatable, CaseIterable {
        case none
        case useControlChannel
        case usePrimaryTransport
    }

    /// Measured from the moment the session became ready, so the first three seconds are a probe:
    /// nothing extra is sent to ask whether the path works.
    public static let silenceBeforeFallback: TimeInterval = 3

    /// The client pings once a second, so a pong inside five seconds is four missed round trips.
    /// Moving video onto a channel that is itself failing would take the picture off the one lane
    /// still working.
    public static let controlHealthWindow: TimeInterval = 5

    /// Also the cooling-off period after a return to the preferred transport, so a lane just given
    /// a second chance gets these seconds to prove itself.
    public static let requestRepeatInterval: TimeInterval = 5

    public static let minFallbackHold: TimeInterval = 5

    /// Two, not one: the host probes that transport with keyframes while video is on the control
    /// channel, and a single datagram does get through on a path otherwise losing everything.
    public static let primaryPicturesForReturn = 2

    /// The `low` tier: the host applies it as a ceiling and the client stops asking for more while
    /// it is in force, which is what makes a capped session read as deliberately reduced rather
    /// than broken.
    public static let controlChannelBitrateKbps = VideoQualityTier.low.rawValue

    /// The client sends its tier the moment a session is ready, so reaching this means the command
    /// was lost rather than that nobody spoke.
    public static let preferredTransportBitrateKbps = VideoQualityTier.high.rawValue

    public private(set) var isFallback = false

    private var lastRequestAt: TimeInterval?
    private var fellBackAt: TimeInterval = 0
    private var primaryPictures = 0

    public init() {}

    /// `now` is monotonic seconds, not a wall clock: a device syncing its time must not trip it.
    public mutating func advance(
        now: TimeInterval,
        lastPictureAt: TimeInterval?,
        lastControlReplyAt: TimeInterval?,
        applies: Bool
    ) -> Decision {
        guard applies else { return .none }

        if isFallback {
            if now - fellBackAt >= Self.minFallbackHold,
               primaryPictures >= Self.primaryPicturesForReturn {
                isFallback = false
                primaryPictures = 0
                lastRequestAt = now
                return .usePrimaryTransport
            }

            // The host is entitled to decline a request: a Mac producing nothing cannot tell a
            // blocked path from a still screen either. A request that produced no picture is
            // therefore repeated rather than assumed to have worked.
            let askedAt = lastRequestAt ?? 0
            let picturedSinceAsking = lastPictureAt.map { $0 > askedAt } ?? false
            if !picturedSinceAsking, now - askedAt >= Self.requestRepeatInterval {
                lastRequestAt = now
                return .useControlChannel
            }
            return .none
        }

        guard let lastPictureAt, now - lastPictureAt >= Self.silenceBeforeFallback else { return .none }
        // The control channel has to be demonstrably alive: it is about to carry the session's
        // whole picture, and a lane failing on its own would turn one broken direction into two.
        guard let lastReply = lastControlReplyAt, now - lastReply <= Self.controlHealthWindow else {
            return .none
        }
        if let lastRequestAt, now - lastRequestAt < Self.requestRepeatInterval { return .none }

        lastRequestAt = now
        fellBackAt = now
        primaryPictures = 0
        isFallback = true
        return .useControlChannel
    }

    public mutating func notePrimaryPicture() {
        guard isFallback else { return }
        primaryPictures += 1
    }

    public mutating func reset() {
        isFallback = false
        lastRequestAt = nil
        fellBackAt = 0
        primaryPictures = 0
    }
}
