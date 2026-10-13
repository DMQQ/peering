import Foundation
import PeeringKit
import RemoteCore

extension SessionModel {
    /// Called when the Mac list or the network path changes. Waits for the Mac to stay in view, then moves any session on
    /// the relay or a punched hole to the LAN, even with a picture up: a short interruption beats staying on a worse
    /// path until the user notices.
    func considerLANUpgrade() {
        guard lanUpgradeTask == nil, sessions.contains(where: { $0.phase == .ready && $0.connectionPath != .lan }) else { return }
        lanUpgradeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LANUpgradePolicy.settleSeconds))
            guard !Task.isCancelled, let self else { return }
            lanUpgradeTask = nil
            upgradeSessionsToLAN()
        }
    }

    private func upgradeSessionsToLAN() {
        for session in sessions where session.phase == .ready {
            guard let hostID = session.hostID, let host = hosts.first(where: { $0.id == hostID }) else { continue }
            let sinceLast = lastLANUpgradeAt[hostID].map { Date().timeIntervalSince($0) }
            guard LANUpgradePolicy.shouldUpgrade(path: session.connectionPath, macVisibleOnLAN: true, secondsSinceLastAttempt: sinceLast) else { continue }
            lastLANUpgradeAt[hostID] = Date()
            session.logEvent("The Mac is on this network, moving to the LAN")
            isResuming = true
            reconnect(session, to: .discovered(host))
        }
    }
}
