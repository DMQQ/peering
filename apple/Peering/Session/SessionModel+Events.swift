import PeeringKit
import RemoteCore
import SwiftUI

/// Discovery is a fact about the phone's network, not any one connection, so the list stays here; session events apply to the session that delivered them.
extension SessionModel {
    /// Giving up takes ten seconds and restarting the Mac app takes longer, so the phone was left on the picker with the Mac sitting in it.
    private func redialMacsThatCameBack(_ reappeared: [DiscoveredHost]) {
        for host in reappeared {
            guard let session = sessions.first(where: { $0.hostID == host.id && $0.hasGivenUpResuming }),
                  let gaveUpAt = session.gaveUpAt,
                  gaveUpAt.isWithin(seconds: Self.comebackWindow)
            else { continue }
            isResuming = true
            reconnect(session, to: .discovered(host))
        }
    }

    static let comebackWindow: TimeInterval = 120

    func apply(_ event: HostBrowser.Event) {
        switch event {
        case .denied:
            localNetworkDenied = true
            browseStatus = String(localized: "Peering cannot look for Macs because Local Network access is off. Turn it on in Settings.")
        case .started:
            localNetworkDenied = false
            browseFailed = false
            browseStatus = String(localized: "Looking for Macs on this network…")
        case .updated(let hosts):
            localNetworkDenied = false
            browseFailed = false
            let reappeared = hosts.filter { host in !self.hosts.contains { $0.id == host.id } }
            self.hosts = hosts
            redialMacsThatCameBack(reappeared)
            if let pending = pendingHostID, let host = hosts.first(where: { $0.id == pending }) {
                pendingHostID = nil
                connect(to: .discovered(host))
            }
            // On a lost cold-launch race with Bonjour, switch relay to LAN once the Mac appears, but only while the relay has nothing on screen: once a picture is carrying, an interruption costs more than the relay.
            // "Nothing on screen yet", not "still dialling": a suspended browser finds the Mac after the dial, and the Mac was left on a relay in another country. See `hasHadPicture`.
            // Replaced rather than dialled beside it: the upgraded session has no `hostID` yet, so as a new Mac it hit the plan gate and offered a second-Mac paywall mid-connect.
            if let session = activeSession,
               session.connectionPath == .relay,
               session.phase != .ready || !session.hasHadPicture,
               let hostID = UserDefaults.standard.string(forKey: Self.lastHostIDKey),
               let host = hosts.first(where: { $0.id == hostID }) {
                // Marked as the app's own attempt: without the flag the handover is a Mac being opened and the connecting card covers a session that is only changing path. See `isComingBack`.
                isResuming = true
                reconnect(session, to: .discovered(host))
            }
            considerLANUpgrade()
            self.resumeIfNeeded()
            browseStatus = hosts.isEmpty
                ? String(localized: "No Macs found yet. Make sure Peering is running on your Mac and on the same network, or pair with a Mac that is not on your network.")
                : (hosts.count == 1 ? String(localized: "1 Mac found") : String(localized: "\(hosts.count) Macs found"))
        case .failed(let message):
            // Bonjour fails silently without the local-network permission and the NSBonjourServices entry, so the message is surfaced verbatim; the manual address path is the way past.
            // Shown though the browser is replacing itself: the retry takes half a minute.
            browseFailed = true
            browseStatus = String(localized: "Browsing failed: \(message)")
        }
    }
}