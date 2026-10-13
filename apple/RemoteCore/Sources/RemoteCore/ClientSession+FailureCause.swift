import Foundation
import Network

extension ClientSession {
    /// Why a failure happened, from a closed set so the app can say it in the user's language.
    ///
    /// ``Failure/errorDescription`` stays English for logs. A few cases carry what the sentence names (a Mac's ID, a version, text the Mac or relay wrote): those values are for display only and must never reach analytics, which reads ``FailureReason``.
    public enum FailureCause: Sendable, Equatable {
        case sessionBusy
        case anotherDeviceConnected
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
        case protocolMismatch(client: UInt16, host: UInt16)
        /// The key of the Mac at this address is not the one pinned for it.
        case identityChanged(hostID: String)
        case noPinOnFile(hostID: String)
        case hostIDMismatch(dialled: String, answered: String)
        /// The relay refused a pair whose protocol versions differ. Either number is nil when the relay's sentence could not be read.
        case relayVersionMismatch(host: Int?, client: Int?)
        case relayRefused(message: String)
        case hostRefused(message: String)

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
            case .refused(let message): self = .hostRefused(message: message)
            case .invalidPort, .cancelled, .transport: return nil
            }
        }
    }
}

extension ClientSession.FailureCause {
    /// How the connect screen words a failure on a relay connection that its cause alone decides.
    public enum Card: Sendable, Equatable {
        case hostNotRegistered
        case identityChanged
        case wrongMac
        case updateThisApp
        case updateTheMac
    }

    public var card: Card? {
        switch self {
        case .relayHostOffline: return .hostNotRegistered
        case .identityChanged: return .identityChanged
        case .hostIDMismatch: return .wrongMac
        case .relayVersionMismatch(let host, let client):
            // When either number is unknown the Mac is blamed: the relay's own wording leaves no better guess.
            if let host, let client, client < host { return .updateThisApp }
            return .updateTheMac
        default: return nil
        }
    }
}

extension ClientSession.Failure {
    var cause: ClientSession.FailureCause? {
        switch self {
        case .busy: return .sessionBusy
        case .anotherDeviceConnected: return .anotherDeviceConnected
        case .handshakeTimedOut: return .handshakeTimedOut
        case .pinsUnreadable: return .pinsUnreadable
        case .commitmentMismatch, .noServerKey, .unexpected: return .handshakeUnreadable
        case .protocolMismatch(let client, let host): return .protocolMismatch(client: client, host: host)
        case .pinMismatch(let hostID): return .identityChanged(hostID: hostID)
        case .noPinOnFile(let hostID): return .noPinOnFile(hostID: hostID)
        case .hostIDMismatch(let dialled, let answered): return .hostIDMismatch(dialled: dialled, answered: answered)
        case .identity: return nil
        }
    }
}

extension RelaySignallingError {
    var cause: ClientSession.FailureCause? {
        switch self {
        case .timedOut: return .relayTimedOut
        case .hostOffline: return .relayHostOffline
        case .nonWebSocketResponse, .unexpectedResponse: return .relayUnavailable
        case .refused(let code, let message):
            guard code == Self.versionRefusalCode else { return .relayRefused(message: message) }
            let versions = Self.versions(inRefusal: message)
            return .relayVersionMismatch(host: versions.host, client: versions.client)
        }
    }

    /// The relay's code for a pair whose protocol versions differ.
    static let versionRefusalCode = "version"

    /// The two numbers in the relay's "host speaks v1, client speaks v2".
    static func versions(inRefusal message: String) -> (host: Int?, client: Int?) {
        (version(in: message, after: "host speaks v"), version(in: message, after: "client speaks v"))
    }

    private static func version(in message: String, after marker: String) -> Int? {
        guard let range = message.range(of: marker) else { return nil }
        return Int(message[range.upperBound...].prefix(while: { $0.isASCII && $0.isNumber }))
    }
}
