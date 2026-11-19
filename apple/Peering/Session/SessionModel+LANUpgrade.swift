import Foundation
import PeeringKit
import RemoteCore

extension SessionModel {
    private var hasSessionOffTheLAN: Bool {
        // A QUIC session moves its own connection onto the LAN when the Mac is reachable there; a new LAN session would only interrupt it.
        sessions.contains { $0.phase == .ready && $0.connectionPath != .lan && $0.wire?.isOnQuic != true }
    }

    /// Called when the Mac list or the network path changes. Looks again every few seconds for as long as a session is
    /// ready and off the LAN, and moves it once the Mac has stayed in view: a short interruption beats staying on a worse
    /// path until the user notices. One missed trigger (the Mac not yet in view, a failed dial) no longer leaves the
    /// session there for good.
    func considerLANUpgrade() {
        guard lanUpgradeTask == nil, hasSessionOffTheLAN else { return }
        lanUpgradeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LANUpgradePolicy.settleSeconds))
            while !Task.isCancelled {
                guard let self, hasSessionOffTheLAN else { break }
                if LANUpgradePolicy.canReachLAN(interface: networkContext.interface) { upgradeSessionsToLAN() }
                try? await Task.sleep(for: .seconds(LANUpgradePolicy.pollSeconds))
            }
            self?.lanUpgradeTask = nil
        }
    }

    /// A different network is a new chance: the attempts counted against the last one say nothing about this one.
    func networkPathChangedForLANUpgrade() {
        lanUpgradeAttempts.removeAll()
        if hasSessionOffTheLAN, LANUpgradePolicy.canReachLAN(interface: networkContext.interface) {
            // A browser started on the old network can miss the Mac on the new one.
            restartBrowsing()
        }
        considerLANUpgrade()
    }

    /// The cooldown and cap, read without spending anything: a probe is free, a move is not.
    func mayTryLANUpgrade(hostID: String, path: ConnectionPath?) -> Bool {
        let sinceLast = lastLANUpgradeAt[hostID].map { Date().timeIntervalSince($0) }
        return LANUpgradePolicy.shouldUpgrade(
            path: path,
            macVisibleOnLAN: true,
            secondsSinceLastAttempt: sinceLast,
            attemptsOnThisNetwork: lanUpgradeAttempts[hostID] ?? 0
        )
    }

    /// One place that spends an attempt, so every route to the LAN counts against the same cooldown and cap.
    func claimLANUpgradeAttempt(hostID: String, path: ConnectionPath?) -> Bool {
        guard mayTryLANUpgrade(hostID: hostID, path: path) else { return false }
        lastLANUpgradeAt[hostID] = Date()
        lanUpgradeAttempts[hostID, default: 0] += 1
        return true
    }

    /// Asked of the LAN first, off to the side: the session in use is only replaced once the Mac has answered there, so a LAN that cannot be reached never interrupts the relay.
    private func upgradeSessionsToLAN() {
        for session in sessions where session.phase == .ready && session.wire?.isOnQuic != true {
            guard let hostID = session.hostID, let host = hosts.first(where: { $0.id == hostID }),
                  mayTryLANUpgrade(hostID: hostID, path: session.connectionPath),
                  lanProbesInFlight.insert(hostID).inserted
            else { continue }
            Task { [weak self, weak session] in
                let began = ContinuousClock.now
                let reachable = await LANProbe.isReachable(host.endpoint)
                guard let self else { return }
                lanProbesInFlight.remove(hostID)
                let elapsed = (ContinuousClock.now - began).formatted(.units(allowed: [.milliseconds], width: .narrow))
                session?.logEvent(reachable ? "LAN probe answered in \(elapsed)" : "LAN probe got no answer in \(elapsed), staying put")
                guard reachable, let session, session.phase == .ready, session.connectionPath != .lan,
                      claimLANUpgradeAttempt(hostID: hostID, path: session.connectionPath)
                else { return }
                session.logEvent("The Mac answered on this network, moving to the LAN")
                isResuming = true
                reconnect(session, to: .discovered(host))
            }
        }
    }
}
