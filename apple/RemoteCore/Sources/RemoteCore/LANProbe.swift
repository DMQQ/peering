import Foundation
import Network

/// A bare TCP connect to a Mac's LAN endpoint, to learn whether the LAN can carry a session before one is moved onto it. It never speaks the protocol and never touches a live session, so a Mac that cannot be reached costs nothing.
public enum LANProbe {
    /// Cellular is prohibited: a probe that quietly went over it would answer for the wrong network.
    public static func isReachable(_ endpoint: NWEndpoint, timeout: TimeInterval = 2) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "pl.dmq.peering.lan-probe")

        return await withCheckedContinuation { continuation in
            // Resumed once, from the probe's own queue: the state handler and the timeout both run on it.
            nonisolated(unsafe) var finished = false
            let finish: @Sendable (Bool) -> Void = { reachable in
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready: finish(true)
                // A refused or unroutable connect parks in `.waiting` rather than failing.
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            connection.start(queue: queue)
        }
    }
}
