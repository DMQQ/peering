import MacCastKit
import RemoteCore
import SwiftUI

/// What arrives from discovery, turned into state.
///
/// **The half of the event handling that is not about a Mac.** Bonjour is a fact about the
/// phone's network rather than about any one connection: the list of Macs it can see is the same
/// list whichever of them is on screen, so the list stays here. Everything that arrives from a
/// session is applied to the session that delivered it, and lives on ``MacSession`` — see
/// ``MacSession/apply(_:)``, and the note there for why that separation is the point.
extension SessionModel {
    func apply(_ event: HostBrowser.Event) {
        switch event {
        case .started:
            browseFailed = false
            browseStatus = "Looking for Macs on this network…"
        case .updated(let hosts):
            browseFailed = false
            self.hosts = hosts
            if let pending = pendingHostID, let host = hosts.first(where: { $0.id == pending }) {
                pendingHostID = nil
                connect(to: .discovered(host))
            }
            self.resumeIfNeeded()
            // The second sentence matters more than it did: an empty list here is now the
            // moment to look at the other way in, which is the row directly below this text.
            browseStatus = hosts.isEmpty
                ? "No Macs found yet. Make sure Peering is running on your Mac and on the same network, or pair with a Mac that is not on your network."
                : "\(hosts.count) Mac\(hosts.count == 1 ? "" : "s") found"
        case .failed(let message):
            // Bonjour failing is silent on iOS without the local-network permission and the
            // NSBonjourServices entry, so the message is surfaced verbatim rather than
            // smoothed over — the manual address path below is the way past it.
            //
            // Shown even though the browser is already replacing itself: the retry can take half
            // a minute, and a status line that said nothing would leave the user looking at a
            // list that has quietly stopped updating.
            browseFailed = true
            browseStatus = "Browsing failed: \(message)"
        }
    }
}