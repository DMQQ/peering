import Foundation
import Network

/// Where a connection was when it failed, from a closed set: the failure reason says what went wrong and this says how far the session had got.
public enum ConnectStage: String, Sendable, CaseIterable, Comparable {
    case resolving, connecting, tls, handshake, pairing, ready, streaming, video

    private var order: Int {
        switch self {
        case .resolving: 0
        case .connecting: 1
        case .tls: 2
        case .handshake: 3
        case .pairing: 4
        case .ready: 5
        case .streaming: 6
        case .video: 7
        }
    }

    public static func < (lhs: ConnectStage, rhs: ConnectStage) -> Bool { lhs.order < rhs.order }

    /// `tracked` is the last stage the session entered. A TLS error surfaces while the socket is still connecting, so it is moved to `tls`; a lost picture is the video stage whatever the control channel was doing.
    public static func atFailure(tracked: ConnectStage, reason: ClientSession.FailureReason, detail: TransportErrorDetail?) -> ConnectStage {
        if reason == .videoLost { return .video }
        if tracked == .connecting, detail?.domain == .tls { return .tls }
        return tracked
    }
}

/// An `NWError` reduced to its domain and number. Never the message or the endpoint, which can hold an address.
public struct TransportErrorDetail: Sendable, Equatable {
    public enum Domain: String, Sendable, CaseIterable {
        /// `code` is an errno.
        case posix
        /// `code` is a `DNSServiceErrorType`.
        case dns
        /// `code` is an `OSStatus`, which is where a TLS alert lands.
        case tls
    }

    public let domain: Domain
    public let code: Int

    public init(domain: Domain, code: Int) {
        self.domain = domain
        self.code = code
    }

    public init?(_ error: Error) {
        switch error as? NWError {
        case .posix(let code): self.init(domain: .posix, code: Int(code.rawValue))
        case .dns(let code): self.init(domain: .dns, code: Int(code))
        case .tls(let status): self.init(domain: .tls, code: Int(status))
        default: return nil
        }
    }
}
