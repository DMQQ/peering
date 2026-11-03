import Foundation

/// The host's half of ``VideoFallbackPolicy``: whether a request to move video onto the control channel
/// would put a picture on the client's screen.
public enum HostFallbackGate {
    public enum Answer: Sendable, Equatable {
        case serve
        case decline
    }

    /// How recently the encoder must have produced something for a missing picture to be the network's
    /// doing rather than there being no picture.
    public static let producingWindow: TimeInterval = 5

    /// A held keyframe is enough on its own: it is resent on the new lane, so a client whose first picture
    /// was lost on a blocked path gets one even while the screen stays still and nothing new is encoded.
    public static func answer(
        now: TimeInterval,
        lastProducedAt: TimeInterval?,
        holdsRecoveryPoint: Bool
    ) -> Answer {
        if holdsRecoveryPoint { return .serve }
        guard let lastProducedAt, now - lastProducedAt <= producingWindow else { return .decline }
        return .serve
    }
}
