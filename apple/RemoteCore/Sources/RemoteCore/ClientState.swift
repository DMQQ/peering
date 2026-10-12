import Foundation

/// The body of ``MessageKind/clientState``.
public struct ClientStatePayload: Codable, Sendable, Equatable {
    public var background: Bool

    public init(background: Bool) {
        self.background = background
    }
}

public enum ClientStateSupport {
    /// An older host treats an unknown kind as a protocol error, so the notice goes only to a host that declared it.
    public static func maySend(toHostDeclared declared: Bool?) -> Bool {
        declared == true
    }
}

/// How long the host lets a session stay silent before ending it.
public enum SessionSilenceLimits {
    public static let authorized: TimeInterval = 60
    public static let handshake: TimeInterval = 30
    public static let approval: TimeInterval = 120
    /// A frozen phone sends nothing at all, so a session that said it left the foreground gets longer than a live one. One that never returns is still reaped.
    public static let backgrounded: TimeInterval = 180

    public static func limit(isAuthorized: Bool, clientInBackground: Bool) -> TimeInterval {
        guard isAuthorized else { return handshake }
        return clientInBackground ? backgrounded : authorized
    }
}

/// Per-session state on the host: whether the client said it left the foreground, and whether the picture should run as a result.
public struct ClientPictureState: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        case pauseVideo
        case resumeVideo
    }

    public private(set) var inBackground = false
    private var userPausedPicture = false

    public init() {}

    /// A repeat of the current state does nothing, and a client that paused the picture itself keeps it paused when it comes back.
    public mutating func clientBackground(_ background: Bool) -> Action {
        guard background != inBackground else { return .none }
        inBackground = background
        guard !userPausedPicture else { return .none }
        return background ? .pauseVideo : .resumeVideo
    }

    /// The client's own `setVideoEnabled`. While it is in the background a resume is held back until it returns.
    public mutating func pictureRequested(_ enabled: Bool) -> Action {
        userPausedPicture = !enabled
        guard !inBackground else { return .none }
        return enabled ? .resumeVideo : .pauseVideo
    }
}
