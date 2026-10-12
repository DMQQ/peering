import Foundation
import MacCastKit
import Network
import RemoteCore
import os

private let admissionLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

/// Where an inbound connection came from. A relay tunnel dials the listener over loopback, so only a loopback source can be one.
struct ConnectionOrigin {
    let address: String
    let loopbackPort: UInt16?

    init(_ connection: NWConnection) {
        guard case .hostPort(let host, let port) = connection.endpoint else {
            address = "unknown"
            loopbackPort = nil
            return
        }
        var isLoopback = false
        switch host {
        case .ipv4(let v4):
            isLoopback = v4.isLoopback
        case .ipv6(let v6):
            isLoopback = v6.isLoopback || (v6.asIPv4?.isLoopback ?? false)
        default:
            break
        }
        address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        loopbackPort = isLoopback ? port.rawValue : nil
    }
}

extension HostServer {
    func claimRelayTunnel(loopbackPort: UInt16?) -> RelayTunnel? {
        let ports = Dictionary(uniqueKeysWithValues: pendingRelayBridges.compactMap { tunnel in
            tunnel.bridge.localSourcePort.map { (tunnel.id, $0) }
        })
        guard let id = tunnelMatcher.claim(loopbackPort: loopbackPort, knownPorts: ports, now: Date()),
              let index = pendingRelayBridges.firstIndex(where: { $0.id == id })
        else { return nil }
        let tunnel = pendingRelayBridges.remove(at: index)
        activeRelayBridges.append(tunnel)
        return tunnel
    }

    func admitBeforeAuthentication(address: String) -> Bool {
        let waiting = controlSessions.filter { !$0.isAuthorized && !$0.isVideoConnection }.map(\.address)
        let decision = PreAuthAdmission.decide(unauthenticatedAddresses: waiting, newAddress: address)
        guard decision != .admit else { return true }
        admissionLog.notice("refused a connection before its handshake: \(String(describing: decision), privacy: .public)")
        return false
    }

    /// Runs on the reaper: closes relay tunnels that no connection claimed in time, and frees a pairing prompt held too long.
    func reapStalePairingAndTunnels() {
        for id in tunnelMatcher.expire(now: Date()) {
            admissionLog.notice("a relay tunnel expired before a connection claimed it")
            pendingRelayBridges.first { $0.id == id }?.bridge.cancel()
            pendingRelayBridges.removeAll { $0.id == id }
        }
        if let stale = pairingGate.evictStaleHolder(now: Date()) {
            emit(.pairingAbandoned(sessionID: stale))
            controlSessions.first { $0.id == stale }?.cancel()
        }
    }

    /// A departing client's held buttons and keys are released while another client stays; the last one out is handled by the model's full release.
    func releaseHeldInput(of session: HostSession) {
        guard controlSessions.contains(where: { $0.isAuthorized }) else { return }
        for command in session.heldInput.releaseCommands() { onCommand?(command) }
    }
}
