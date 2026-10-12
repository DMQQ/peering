import Foundation
import MacCastKit
import RemoteCore

extension HostServer {
    func connectThroughRelay(_ relaySession: RelaySession) {
        queue.async { [weak self] in
            guard let self, isListening else { return }
            let tunnelID = UUID()
            guard connections.reserveTunnel(tunnelID, now: .now) else {
                emit(.failed("Too many relay tunnels are waiting; one was refused"))
                return
            }
            do {
                let bridge = try RelayControlBridge(
                    session: relaySession,
                    localPort: port,
                    onClose: { [weak self] in
                        self?.queue.async { [weak self] in
                            self?.connections.releaseTunnel(id: tunnelID)
                        }
                    }
                )
                connections.addPending(HostConnections.RelayTunnel(id: tunnelID, bridge: bridge, session: relaySession))
                bridge.start()
            } catch {
                connections.releaseTunnel(id: tunnelID)
                Analytics.failed(error, in: .network)
                emit(.failed("Could not open the relay control tunnel: \(error.localizedDescription)"))
            }
        }
    }
}
