import Foundation

/// One HTTP header. A pair rather than a dictionary because a response may repeat a name and order is the sender's.
public struct PreviewHeader: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One HTTP request for a server on the Mac's own loopback, as the phone's web preview asks for it.
///
/// There is no host field on purpose: the Mac always dials `127.0.0.1`, so nothing the phone sends can name another machine. See ``PreviewProxyPolicy``.
public struct PreviewProxyRequest: Codable, Equatable, Sendable {
    /// Chosen by the phone and echoed on every event of the answer.
    public let id: UInt32
    public let port: UInt16
    public let method: String
    /// Path and query, starting with a single `/`.
    public let target: String
    public let headers: [PreviewHeader]
    public let body: Data?

    public init(id: UInt32, port: UInt16, method: String, target: String, headers: [PreviewHeader] = [], body: Data? = nil) {
        self.id = id
        self.port = port
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }
}

public enum PreviewProxyCommand: Codable, Equatable, Sendable {
    case fetch(PreviewProxyRequest)
    /// The page stopped waiting (navigated away, reloaded). The Mac drops the transfer.
    case cancel(id: UInt32)
}

/// Why a request got no answer. A closed set, so the phone can word each one and none carries a Mac's details.
public enum PreviewFailure: String, Codable, Equatable, Sendable {
    /// The request itself was malformed.
    case invalidRequest
    /// A port or method the proxy does not serve.
    case notAllowed
    /// Nothing is accepting connections on that port.
    case notListening
    case timedOut
    case tooLarge
    /// Too many requests already in flight.
    case busy
    /// The phone's own link to the Mac was gone before an answer came.
    case disconnected
    case failed
}

/// The answer, in pieces: a head, then bodies of at most ``PreviewProxyLimits/chunkBytes``, then an end. Pieces rather than one frame so a large file never holds the control channel's mouse moves behind it.
public enum PreviewProxyEvent: Codable, Equatable, Sendable {
    case head(id: UInt32, status: Int, headers: [PreviewHeader])
    case body(id: UInt32, data: Data)
    /// `truncated` means the body hit ``PreviewProxyLimits/maxResponseBytes`` and the rest was dropped.
    case end(id: UInt32, truncated: Bool)
    case failure(id: UInt32, reason: PreviewFailure)

    public var requestID: UInt32 {
        switch self {
        case .head(let id, _, _), .body(let id, _), .end(let id, _), .failure(let id, _): id
        }
    }

    /// Whether nothing more follows for this request.
    public var isFinal: Bool {
        switch self {
        case .end, .failure: true
        case .head, .body: false
        }
    }
}

public enum PreviewProxyLimits {
    public static let maxRequestBodyBytes = 256 * 1024
    /// A request frame is JSON with the body in base64, so this leaves room for it plus headers.
    public static let maxRequestFrameBytes = 512 * 1024
    public static let maxResponseBytes = 8 * 1024 * 1024
    public static let chunkBytes = 48 * 1024
    public static let maxHeaderCount = 64
    public static let maxTargetLength = 8 * 1024
    public static let maxInFlightPerClient = 16
    /// The largest text body the phone will read through for loopback URLs to rewrite.
    public static let maxRewriteBytes = 2 * 1024 * 1024
}
