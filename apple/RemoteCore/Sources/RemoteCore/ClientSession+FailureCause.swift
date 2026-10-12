import Foundation
import Network

extension ClientSession {
    /// A failure whose wording needs no name, address or number, from a closed set so the app can say it in the user's language.
    ///
    /// ``Failure/errorDescription`` stays English for logs. A failure that names a Mac, a version or text the Mac wrote has no cause here: the app shows its sentence as it came.
    public enum FailureCause: Sendable, Equatable {
        case sessionBusy
        case handshakeTimedOut
        case handshakeUnreadable
        case pinsUnreadable
        case pairingNotSaved
        case connectTimedOut
        case hostClosed
        case hostUnresponsive
        case videoLost
        case relayTimedOut
        case relayHostOffline
        case relayUnavailable
        case network(NetworkFailureText.Kind)

        init?(_ error: Error) {
            let cause: FailureCause?
            switch error {
            case let failure as Failure: cause = failure.cause
            case let failure as ClientConnection.Failure: cause = FailureCause(failure)
            case let failure as RelaySignallingError: cause = failure.cause
            case is RelayTunnelError, is RelayProtocolError: cause = .relayUnavailable
            case let failure as NWError: cause = .network(NetworkFailureText.kind(of: failure))
            case is FramingError: cause = .handshakeUnreadable
            default: cause = nil
            }
            guard let cause else { return nil }
            self = cause
        }

        init?(_ failure: ClientConnection.Failure) {
            switch failure {
            case .timedOut: self = .connectTimedOut
            case .hostClosed: self = .hostClosed
            case .network(let kind): self = .network(kind)
            case .malformed: self = .handshakeUnreadable
            case .invalidPort, .cancelled, .refused, .transport: return nil
            }
        }
    }
}

extension ClientSession.Failure {
    var cause: ClientSession.FailureCause? {
        switch self {
        case .busy: return .sessionBusy
        case .handshakeTimedOut: return .handshakeTimedOut
        case .pinsUnreadable: return .pinsUnreadable
        case .commitmentMismatch, .noServerKey, .unexpected: return .handshakeUnreadable
        case .protocolMismatch, .pinMismatch, .noPinOnFile, .hostIDMismatch, .identity: return nil
        }
    }
}

extension RelaySignallingError {
    var cause: ClientSession.FailureCause? {
        switch self {
        case .timedOut: return .relayTimedOut
        case .hostOffline: return .relayHostOffline
        case .nonWebSocketResponse, .unexpectedResponse: return .relayUnavailable
        case .refused: return nil
        }
    }
}
