import Foundation
import PeeringKit
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
    func admitBeforeAuthentication(address: String) -> Bool {
        let decision = PreAuthAdmission.decide(unauthenticatedAddresses: connections.unauthenticatedAddresses, newAddress: address)
        guard decision != .admit else { return true }
        admissionLog.notice("refused a connection before its handshake: \(String(describing: decision), privacy: .public)")
        return false
    }

    /// Runs on the reaper: closes relay tunnels that no connection claimed in time, and frees a pairing prompt held too long.
    func reapStalePairingAndTunnels() {
        for tunnel in connections.expireUnclaimedTunnels(now: .now) {
            admissionLog.notice("a relay tunnel expired before a connection claimed it")
            tunnel.bridge.cancel()
        }
        if let stale = connections.evictStalePairingHolder(now: .now) {
            emit(.pairingAbandoned(sessionID: stale))
            connections.session(id: stale)?.cancel()
        }
    }

    /// One device drives the Mac at a time. A device that went quiet is replaced, so a phone that vanished does not lock the Mac for the others.
    /// Nothing is displaced here: the newcomer has not paired yet, and a stranger must not be able to cut off a phone by asking.
    func admitDevice(clientID: String, takesOver: Bool, joining session: HostSession) -> Bool {
        let rivals = connections.sessions.filter { $0.isAuthorized && $0 !== session }
        let decision = SingleDevicePolicy.decide(
            newcomer: clientID,
            others: rivals.map {
                SingleDevicePolicy.Peer(clientID: $0.clientID, silence: $0.silence, inBackground: $0.pictureState.inBackground)
            },
            takesOver: takesOver
        )
        switch decision {
        case .refuse:
            admissionLog.notice("turned away a second device while another is connected")
            return false
        case .admit(let evicting):
            session.rivalsToEvict = evicting
            return true
        }
    }

    /// Carries out what ``admitDevice(clientID:takesOver:joining:)`` decided, now that the newcomer is authorised.
    func evictRivals(of session: HostSession) {
        let evicting = session.rivalsToEvict
        session.rivalsToEvict = []
        guard !evicting.isEmpty else { return }
        connections.sessions
            .filter { $0.isAuthorized && $0 !== session && evicting.contains($0.clientID) }
            .forEach { $0.cancel() }
    }

    /// A departing client's held buttons and keys are released while another client stays; the last one out is handled by the model's full release.
    func releaseHeldInput(of session: HostSession) {
        guard connections.hasAuthorizedSession else { return }
        for command in session.heldInput.releaseCommands() { callbacks.onCommand?(command) }
    }
}
