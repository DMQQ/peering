import Foundation
import PeeringKit
import RemoteCore

extension SessionModel {
    private var hasSessionOffTheLAN: Bool {
        sessions.contains { $0.phase == .ready && $0.connectionPath != .lan }
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

    private func upgradeSessionsToLAN() {
        for session in sessions where session.phase == .ready {
            guard let hostID = session.hostID, let host = hosts.first(where: { $0.id == hostID }) else { continue }
            let sinceLast = lastLANUpgradeAt[hostID].map { Date().timeIntervalSince($0) }
            guard LANUpgradePolicy.shouldUpgrade(
                path: session.connectionPath,
                macVisibleOnLAN: true,
                secondsSinceLastAttempt: sinceLast,
                attemptsOnThisNetwork: lanUpgradeAttempts[hostID] ?? 0
            ) else { continue }
            lastLANUpgradeAt[hostID] = Date()
            lanUpgradeAttempts[hostID, default: 0] += 1
            session.logEvent("The Mac is on this network, moving to the LAN")
            isResuming = true
            reconnect(session, to: .discovered(host))
        }
    }
}
