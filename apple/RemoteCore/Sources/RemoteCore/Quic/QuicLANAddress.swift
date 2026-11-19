import Foundation
import Network

/// Turns a Bonjour-discovered Mac into the numeric address QUIC dials. The Mac's QUIC listener shares its TCP port number, on UDP.
public enum QuicLANAddress {
    public static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 3) async -> QuicAddress? {
        if case .hostPort(let host, let port) = endpoint {
            return QuicAddress.resolve(host: text(of: host), port: port.rawValue)
        }
        // A UDP "connection" sends nothing until written to, but resolving it fills in the remote endpoint the service points at. IPv4 is asked for first: Bonjour otherwise often answers with the IPv6 link-local address, which is only usable with its interface attached.
        if let v4 = await remoteEndpoint(of: endpoint, version: .v4, timeout: timeout) { return v4 }
        return await remoteEndpoint(of: endpoint, version: .any, timeout: timeout)
    }

    private static func remoteEndpoint(of endpoint: NWEndpoint, version: NWProtocolIP.Options.Version, timeout: TimeInterval) async -> QuicAddress? {
        let parameters = NWParameters.udp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = version
        let connection = NWConnection(to: endpoint, using: parameters)
        let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<NWEndpoint?, Never>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(connection.currentPath?.remoteEndpoint)
                case .failed, .cancelled: once.resume(nil)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "pl.dmq.peering.quic.resolve"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
        connection.cancel()
        guard case .hostPort(let host, let port)? = resolved else { return nil }
        return QuicAddress.resolve(host: text(of: host), port: port.rawValue)
    }

    private static func text(of host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): return "\(address)"
        // Kept with its `%interface`: a link-local address means nothing without it.
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint?, Never>?

    init(_ continuation: CheckedContinuation<NWEndpoint?, Never>) { self.continuation = continuation }

    func resume(_ value: NWEndpoint?) {
        let pending = lock.withLock { () -> CheckedContinuation<NWEndpoint?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
